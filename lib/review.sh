# Review result checks, counts and numbering. Sourced by bin/subcon; defines functions only.
# Schema: schema/review.schema.json. Keep this in step with that file.

# review_validate <file>: exit 0 if <file> is a well-formed, consistent review; else 1 with one line on stderr.
review_validate() {
  local file="${1:?review file required}"

  if [[ ! -f "$file" ]] || ! jq -e . "$file" >/dev/null 2>&1; then
    echo "review: not a readable JSON file: $file" >&2
    return 1
  fi

  # Exact key sets: `keys` is sorted, so the lists below are sorted too.
  if ! jq -e '
    def finding_ok:
      type == "object"
      and (keys == ["failure_scenario","file","fix","line","severity","summary"])
      and (.severity | type == "string" and IN("S1","S2","S3"))
      and (.file | type == "string")
      and (.line | type == "number" and . == floor and . >= 0)
      and (.summary | type == "string")
      and (.failure_scenario | type == "string")
      and (.fix | type == "string");
    type == "object"
    and (keys == ["findings","summary","unverified","verdict"])
    and (.verdict | type == "string" and IN("approve","changes","reject"))
    and (.summary | type == "string")
    and (.findings | type == "array" and all(.[]; finding_ok))
    and (.unverified | type == "array" and all(.[]; type == "string"))
  ' "$file" >/dev/null 2>&1; then
    echo "review: result does not match schema/review.schema.json: $file" >&2
    return 1
  fi

  if jq -e '
    ((.findings | length) == 0 and .verdict != "approve")
    or (any(.findings[]; .severity == "S1") and .verdict == "approve")
  ' "$file" >/dev/null 2>&1; then
    jq -r '"review: inconsistent verdict: \(.verdict) with \(.findings | length) finding(s), \([.findings[] | select(.severity == "S1")] | length) of them S1"' "$file" >&2
    return 1
  fi

  return 0
}

# review_counts <file>: {"s1":n,"s2":n,"s3":n} on stdout. Assumes a validated review.
review_counts() {
  jq -c '{
    s1: ([.findings[] | select(.severity == "S1")] | length),
    s2: ([.findings[] | select(.severity == "S2")] | length),
    s3: ([.findings[] | select(.severity == "S3")] | length)
  }' "${1:?review file required}"
}

# review_next_n <dir>: the number for the next review in <dir>, judged by review-<n>.meta.json files.
review_next_n() {
  local dir="${1:?directory required}"
  local max=0 f base n
  for f in "$dir"/review-*.meta.json; do
    [[ -e "$f" ]] || continue
    base="${f##*/review-}"
    base="${base%.meta.json}"
    [[ "$base" =~ ^[0-9]+$ ]] || continue
    n=$((10#$base))
    if ((n > max)); then
      max=$n
    fi
  done
  echo $((max + 1))
}

# review_latest <dir>: path of review-<n>.json with the largest numeric n; exit 1 if there is none.
review_latest() {
  local dir="${1:?directory required}"
  local best="" bestn=-1 f base n
  for f in "$dir"/review-*.json; do
    base="${f##*/}"
    [[ "$base" =~ ^review-([0-9]+)\.json$ ]] || continue
    n=$((10#${BASH_REMATCH[1]}))
    if ((n > bestn)); then
      bestn=$n
      best=$f
    fi
  done
  [[ -n "$best" ]] || return 1
  echo "$best"
}

# ---- subcon review <job-id> -------------------------------------------------
# Design: docs/design/reviewer.md. The reviewer runs in a throwaway clone of the job's base with the
# patch applied and committed, and the result is accepted only if the clone is exactly as it was left.

SUBCON_REVIEW_SCHEMA="$SUBCON_ROOT/schema/review.schema.json"
SUBCON_REVIEW_PROMPT="$SUBCON_ROOT/lib/review-prompt.md"
REVIEW_SNAPSHOT_MESSAGE="subcon: review snapshot"

# review_kill_tree <pid>: stop the process and its descendants, children first.
review_kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null); do
    review_kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

# review_pick <flag-driver> <flag-model>: resolve the reviewer's driver and model into REVIEW_DRIVER and
# REVIEW_MODEL: flag > SUBCON_REVIEW_DRIVER / SUBCON_REVIEW_MODEL > the driver's default (Hydrogen for agy).
# The implementer's SUBCON_DRIVER / SUBCON_MODEL are not used.
review_pick() {
  local flag_driver="$1" flag_model="$2"
  REVIEW_DRIVER="${flag_driver:-${SUBCON_REVIEW_DRIVER:-agy}}"
  require_driver "$REVIEW_DRIVER"
  REVIEW_MODEL="${flag_model:-${SUBCON_REVIEW_MODEL:-}}"
  if [[ -z "$REVIEW_MODEL" ]]; then
    if [[ "$REVIEW_DRIVER" == agy ]]; then
      REVIEW_MODEL="gemini-4-hydrogen-high"
    else
      REVIEW_MODEL="$("$(driver_path "$REVIEW_DRIVER")" default-model)"
    fi
  fi
  [[ "$REVIEW_DRIVER" != agy ]] || warn_consumer_auth
}

# review_snapshot <repo> <rev> <dest> [<patch>]: clone <repo> into <dest> at <rev> without sharing .git,
# apply <patch> when it is not empty, and commit the result. Prints the snapshot commit.
review_snapshot() {
  local repo="$1" rev="$2" dest="$3" patch="${4:-}"
  git clone -q --local --no-checkout "$repo" "$dest" >&2 || return 1
  git -C "$dest" checkout -q --detach "$rev" >&2 || return 1
  if [[ -n "$patch" && -s "$patch" ]]; then
    git -C "$dest" apply --binary "$patch" >&2 || return 1
  fi
  git -C "$dest" add -A >&2 || return 1
  git -C "$dest" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=subcon -c user.email=subcon@localhost \
    commit -q --allow-empty --no-verify -m "$REVIEW_SNAPSHOT_MESSAGE" >&2 || return 1
  git -C "$dest" rev-parse HEAD
}

# review_untouched <clone> <commit>: 0 if the clone is still at <commit> with nothing changed or added.
review_untouched() {
  local clone="$1" commit="$2"
  [[ "$(git -C "$clone" rev-parse HEAD 2>/dev/null)" == "$commit" ]] || return 1
  [[ -z "$(git -C "$clone" status --porcelain --ignored 2>/dev/null)" ]]
}

# review_job_prompt <job-dir> <out>: the instructions, then the ticket, checks, report and patch of the job.
review_job_prompt() {
  local dir="$1" out="$2"
  {
    cat "$SUBCON_REVIEW_PROMPT"
    printf '\n\n--- REVIEW TARGET: a change made for one ticket ---\n\n'
    printf 'The change is already applied and committed as the last commit of the current directory\n'
    printf '(the commit before it is the base). git is not available: read files with cat, grep, head, tail and ls,\n'
    printf 'and use the patch below to see what changed.\n\n'
    printf '## Ticket\n\n'
    cat "$dir/ticket.md"
    printf '\n\n## Checks\n\n'
    jq '.checks' "$dir/result.json"
    printf '\n## Implementer report\n\n'
    jq '.report' "$dir/result.json"
    printf '\n## Patch\n\n'
    if [[ -s "$dir/patch.diff" ]]; then cat "$dir/patch.diff"; else echo "(empty patch)"; fi
  } > "$out"
}

# review_run_driver <work-dir> <driver-dir> <timeout>: run REVIEW_DRIVER in the review role inside <work-dir>.
# Returns the driver's exit code. REVIEW_CHILD holds its pid so a TERM trap can stop the process tree.
review_run_driver() {
  local work="$1" ddir="$2" timeout="$3" pid rc=0
  (
    cd "$work"
    export SUBCON_ROLE=review SUBCON_PROMPT_FILE="$ddir/prompt.txt" SUBCON_JOB_MODEL="$REVIEW_MODEL" \
      SUBCON_TIMEOUT="$timeout" SUBCON_SCHEMA="$SUBCON_REVIEW_SCHEMA" SUBCON_DRIVER="$REVIEW_DRIVER"
    unset SUBCON_CONVERSATION
    exec "$(driver_path "$REVIEW_DRIVER")" "$ddir"
  ) >>"$ddir/log" 2>&1 &
  pid=$!
  REVIEW_CHILD="$pid"
  wait "$pid" || rc=$?
  REVIEW_CHILD=""
  return "$rc"
}

# review_store <store-dir> <base> <meta-json> [<result-file>]: write <base>.json (only when there is a result)
# and then <base>.meta.json, so a meta without a result marks a failed review.
review_store() {
  local store="$1" base="$2" meta="$3" result="${4:-}"
  if [[ -n "$result" ]]; then
    cp "$result" "$store/$base.json.tmp" && mv -f "$store/$base.json.tmp" "$store/$base.json"
  fi
  printf '%s\n' "$meta" | atomic_write "$store/$base.meta.json"
}

# review_reap <pid>: wait up to 3 seconds for the child to exit, then kill it.
review_reap() {
  local pid="$1" i
  for ((i = 0; i < 30; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  kill -KILL "$pid" 2>/dev/null || true
}

# review_workarea: create a work area in REVIEW_TMP and remove it (and stop a running driver) on exit or TERM.
review_workarea() {
  REVIEW_TMP="$(mktemp -d "${TMPDIR:-/tmp}/subcon-review.XXXXXX")" || die "cannot create a work area"
  REVIEW_CHILD=""
  # shellcheck disable=SC2064
  trap 'trap - EXIT INT TERM HUP; if [[ -n "${REVIEW_CHILD:-}" ]]; then review_kill_tree "$REVIEW_CHILD"; review_reap "$REVIEW_CHILD"; fi; rm -rf "'"$REVIEW_TMP"'"; exit 143' INT TERM HUP
  # shellcheck disable=SC2064
  trap 'rm -rf "'"$REVIEW_TMP"'"' EXIT
  mkdir -p "$REVIEW_TMP/driver"
}

# review_conduct <snapshot> <store> <base> <review-id> <job-id|""> <target_type> <repo> <timeout> [<extra-meta-json>]
# Runs the reviewer in $REVIEW_TMP/clone (at <snapshot>) with the prompt in $REVIEW_TMP/driver/prompt.txt,
# checks the clone and the result, and stores <store>/<base>.json (only on success), <base>.meta.json and
# <base>.stream. <extra-meta-json> is merged into the meta. Prints one JSON line and returns 0, 2 (S1) or 4.
review_conduct() {
  local snapshot="$1" store="$2" base="$3" review_id="$4" job_id="$5" target_type="$6" repo="$7" timeout="$8" extra="${9:-}"
  [[ -n "$extra" ]] || extra='{}'
  local tmp="$REVIEW_TMP" created_at error="" driver_rc=0
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -cn --arg repo "$tmp/clone" '{repo: $repo}' > "$tmp/driver/meta.json"
  review_run_driver "$tmp/clone" "$tmp/driver" "$timeout" || driver_rc=$?

  local agy="$tmp/driver/agy.json" result="$tmp/driver/review.json"
  if ! review_untouched "$tmp/clone" "$snapshot"; then
    error="reviewer modified files"
  elif [[ ! -s "$agy" ]] || ! jq -e . "$agy" >/dev/null 2>&1; then
    error="driver produced no result (exit $driver_rc)"
    local why
    why="$(tail -n 1 "$tmp/driver/log" 2>/dev/null | head -c 200)"
    [[ -z "$why" ]] || error="$error: $why"
  elif [[ "$(jq -r '.status // empty' "$agy")" != SUCCESS || "$driver_rc" -ne 0 ]]; then
    error="$(jq -r '.error // empty' "$agy")"
    [[ -n "$error" ]] || error="driver failed (exit $driver_rc)"
  elif ! jq -e '.structured_output | type == "object"' "$agy" >/dev/null 2>&1; then
    error="driver returned no structured output"
  else
    jq -c .structured_output "$agy" > "$result"
    error="$(review_validate "$result" 2>&1 >/dev/null)" || true
    if [[ -n "$error" ]]; then
      rm -f "$result"
      error="${error#review: }"
    fi
  fi

  local meta_agy="null"
  [[ -s "$agy" ]] && jq -e . "$agy" >/dev/null 2>&1 && meta_agy="$(cat "$agy")"
  local meta
  meta="$(jq -cn --argjson agy "$meta_agy" --argjson extra "$extra" --arg id "$review_id" --arg job "$job_id" \
    --arg tt "$target_type" --arg repo "$repo" --arg at "$created_at" --arg driver "$REVIEW_DRIVER" \
    --arg model "$REVIEW_MODEL" --arg err "$error" '{
      v: 1, id: $id, job_id: (if $job == "" then null else $job end), target_type: $tt, repo: $repo,
      created_at: $at, driver: $driver, model: $model,
      duration_seconds: ($agy.duration_seconds? // null), cost_usd: ($agy.cost_usd? // null), usage: ($agy.usage? // null),
      error: (if $err == "" then null else $err end)
    } + $extra')"

  mkdir -p "$store"
  [[ ! -f "$tmp/driver/agy.stream" ]] || cp "$tmp/driver/agy.stream" "$store/$base.stream"

  if [[ -n "$error" ]]; then
    review_store "$store" "$base" "$meta" ""
    json_out '{id: $id, verdict: null, error: $e, path: null}' --arg id "$review_id" --arg e "$error"
    return 4
  fi

  review_store "$store" "$base" "$meta" "$result"
  ( history_append_review "$store/$base.meta.json" "$store/$base.json" ) || echo "subcon: failed to record history for $review_id" >&2

  local counts
  counts="$(review_counts "$store/$base.json")"
  json_out '{id: $id, verdict: $v, s1: $c.s1, s2: $c.s2, s3: $c.s3, path: $p}' \
    --arg id "$review_id" --arg v "$(jq -r .verdict "$store/$base.json")" --argjson c "$counts" --arg p "$store/$base.json"
  [[ "$(jq -r .s1 <<<"$counts")" -eq 0 ]] || return 2
  return 0
}

# ---- subcon review --target and subcon reviews (ticket 61) -------------------

# review_target_check <path>: 0 if <path> is a file committed in HEAD and written as a repo-relative path;
# else 1 with one line on stderr that names <path>.
review_target_check() {
  local t="$1" reason=""
  if [[ "$t" == /* ]]; then
    reason="not a path relative to the repository root"
  elif [[ "/$t/" == *//* || "/$t/" == */./* || "/$t/" == */../* ]]; then
    reason="contains an empty, . or .. element"
  elif [[ "$t" == *[\*\?\[]* ]]; then
    reason="contains a glob character (* ? [)"
  elif ! git cat-file -e "HEAD:$t" 2>/dev/null || [[ "$(git cat-file -t "HEAD:$t" 2>/dev/null)" != blob ]]; then
    reason="not a file committed in HEAD"
  fi
  if [[ -n "$reason" ]]; then
    echo "subcon: invalid review target $t: $reason" >&2
    return 1
  fi
  return 0
}

# review_new_id: <YYYYmmdd-HHMMSS>-<4 hex> (UTC) that no review directory uses yet.
review_new_id() {
  local id
  while :; do
    id="$(date -u +%Y%m%d-%H%M%S)-$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
    [[ -e "$(state_root)/reviews/$id" ]] || break
  done
  echo "$id"
}

# review_target_prompt <brief-or-empty> <out> <target>...: the instructions, then the targets and the brief.
review_target_prompt() {
  local brief="$1" out="$2" t
  shift 2
  {
    cat "$SUBCON_REVIEW_PROMPT"
    printf '\n\n--- REVIEW TARGET: files of the current directory ---\n\n'
    printf 'The current directory is a snapshot of the HEAD commit of the repository, with no uncommitted changes.\n'
    printf 'git is not available: read the files with cat, grep, head, tail and ls.\n\n'
    printf '## Targets\n\n'
    for t in "$@"; do printf -- '- %s\n' "$t"; done
    printf '\n## Brief\n\n'
    if [[ -n "$brief" ]]; then
      cat "$brief"
    else
      printf 'Review the target files for errors, inconsistencies, gaps and weak points.\n'
    fi
  } > "$out"
}

# review_target_run <driver> <model> <timeout> <brief-or-empty> <target>...: review files of HEAD.
# Returns the exit code of review_conduct, or 1 when a target is not a file of HEAD (nothing is created then).
review_target_run() {
  local driver="$1" model="$2" timeout="$3" brief="$4"
  shift 4
  local repo
  repo="$(repo_top)"

  local t bad=0
  for t in "$@"; do
    review_target_check "$t" || bad=1
  done
  [[ "$bad" -eq 0 ]] || return 1
  review_pick "$driver" "$model"

  local head_sha review_id store targets_json extra snapshot="" rc=0
  head_sha="$(git rev-parse HEAD)"
  review_id="$(review_new_id)"
  store="$(state_root)/reviews/$review_id"
  targets_json="$(jq -cn '$ARGS.positional' --args -- "$@")"
  extra="$(jq -cn --arg head "$head_sha" --argjson targets "$targets_json" --arg brief "$brief" \
    '{head: $head, targets: $targets, brief: (if $brief == "" then null else $brief end)}')"

  review_workarea
  if ! snapshot="$(review_snapshot "$repo" HEAD "$REVIEW_TMP/clone" 2>"$REVIEW_TMP/snapshot.err")"; then
    local err meta
    err="failed to prepare the review snapshot: $(head -c 300 "$REVIEW_TMP/snapshot.err" | tr '\n' ' ')"
    mkdir -p "$store"
    meta="$(jq -cn --arg id "$review_id" --arg repo "$repo" --arg driver "$REVIEW_DRIVER" --arg model "$REVIEW_MODEL" \
      --arg e "$err" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson extra "$extra" '{
        v: 1, id: $id, job_id: null, target_type: "target", repo: $repo, created_at: $at, driver: $driver, model: $model,
        duration_seconds: null, cost_usd: null, usage: null, error: $e
      } + $extra')"
    review_store "$store" review "$meta" ""
    json_out '{id: $id, verdict: null, error: $e, path: null}' --arg id "$review_id" --arg e "$err"
    return 4
  fi
  review_target_prompt "$brief" "$REVIEW_TMP/driver/prompt.txt" "$@"
  review_conduct "$snapshot" "$store" review "$review_id" "" target "$repo" "$timeout" "$extra" || rc=$?
  return "$rc"
}

cmd_review() {
  local driver="" model="" timeout="$SUBCON_DEFAULT_TIMEOUT" id="" brief="" brief_given=0
  local targets=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --driver) [[ $# -ge 2 ]] || die "--driver requires a value"; driver="$2"; shift 2 ;;
      --model) [[ $# -ge 2 ]] || die "--model requires a value"; model="$2"; shift 2 ;;
      --timeout) [[ $# -ge 2 ]] || die "--timeout requires a value"; require_timeout "$2"; timeout="$2"; shift 2 ;;
      --target) [[ $# -ge 2 ]] || die "--target requires a value"; targets+=("$2"); shift 2 ;;
      --brief) [[ $# -ge 2 ]] || die "--brief requires a value"; brief="$2"; brief_given=1; shift 2 ;;
      -*) die "unknown option: $1" ;;
      *)
        [[ -z "$id" ]] || die "unexpected argument: $1"
        id="$1"
        shift
        ;;
    esac
  done

  if [[ ${#targets[@]} -gt 0 ]]; then
    [[ -z "$id" ]] || die "a job id cannot be combined with --target"
    if [[ $brief_given -eq 1 ]]; then
      [[ -f "$brief" && -r "$brief" ]] || die "cannot read brief file: $brief"
    fi
    local target_rc=0
    review_target_run "$driver" "$model" "$timeout" "$brief" "${targets[@]}" || target_rc=$?
    return "$target_rc"
  fi
  [[ $brief_given -eq 0 ]] || die "--brief requires --target"
  [[ -n "$id" ]] || die "job id required"

  local dir
  dir="$(job_dir "$id")"
  [[ -d "$dir" ]] || die "unknown job id: $id"
  local cur_repo job_repo
  cur_repo="$(repo_top)"
  job_repo="$(jq -r .repo "$dir/meta.json" 2>/dev/null || echo "")"
  [[ "$job_repo" == "$cur_repo" ]] || die "job repository ($job_repo) does not match current repository ($cur_repo)"

  local res state
  res="$(job_result "$id")" || return 1
  state="$(jq -r .state <<<"$res")"
  [[ "$state" == finished ]] || die "job $id is not finished (state: $state)"

  review_pick "$driver" "$model"

  local n snapshot="" rc=0
  n="$(review_next_n "$dir")"
  # Reserve the number with a placeholder meta (noclobber), so concurrent reviews of one job cannot share it.
  while ! ( set -o noclobber; printf '%s\n' '{"v":1,"error":"review in progress or interrupted"}' > "$dir/review-$n.meta.json" ) 2>/dev/null; do
    n=$((n + 1))
  done
  review_workarea
  if ! snapshot="$(review_snapshot "$cur_repo" "$(jq -r .base "$dir/meta.json")" "$REVIEW_TMP/clone" "$dir/patch.diff" 2>"$REVIEW_TMP/snapshot.err")"; then
    local err
    err="failed to prepare the review snapshot: $(head -c 300 "$REVIEW_TMP/snapshot.err" | tr '\n' ' ')"
    mkdir -p "$dir"
    review_store "$dir" "review-$n" "$(jq -cn --arg id "$id-r$n" --arg job "$id" --arg repo "$cur_repo" --arg driver "$REVIEW_DRIVER" \
      --arg model "$REVIEW_MODEL" --arg e "$err" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{v: 1, id: $id, job_id: $job, target_type: "job", repo: $repo, created_at: $at, driver: $driver, model: $model,
        duration_seconds: null, cost_usd: null, usage: null, error: $e}')" ""
    json_out '{id: $id, verdict: null, error: $e, path: null}' --arg id "$id-r$n" --arg e "$err"
    return 4
  fi
  review_job_prompt "$dir" "$REVIEW_TMP/driver/prompt.txt"
  review_conduct "$snapshot" "$dir" "review-$n" "$id-r$n" "$id" job "$cur_repo" "$timeout" || rc=$?
  return "$rc"
}

# review_summary <result-file>: {"verdict","s1","s2","s3","path"} for a validated result file.
review_summary() {
  local file="$1" verdict counts
  verdict="$(jq -r .verdict "$file")"
  counts="$(review_counts "$file")"
  jq -cn --arg v "$verdict" --argjson c "$counts" --arg p "$file" \
    '{verdict: $v, s1: $c.s1, s2: $c.s2, s3: $c.s3, path: $p}'
}

# review_list_entry <meta> <repo>: the meta with verdict, s1-s3 and path added, as one JSON line.
# Prints nothing for a file that is not a review meta of <repo>. A missing or invalid result gives nulls.
review_list_entry() {
  local meta="$1" repo="$2" base res summary
  base="${meta##*/}"
  [[ "$base" =~ ^review(-[0-9]+)?\.meta\.json$ ]] || return 0
  jq -e --arg r "$repo" '.repo == $r' "$meta" >/dev/null 2>&1 || return 0
  res="${meta%.meta.json}.json"
  summary='{"verdict":null,"s1":null,"s2":null,"s3":null,"path":null}'
  if review_validate "$res" 2>/dev/null; then
    summary="$(review_summary "$res")"
  fi
  jq -c --argjson r "$summary" '. + $r' "$meta"
}

cmd_reviews() {
  local id="" cur_repo dir job_repo f out=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -*) die "unknown option: $1" ;;
      *)
        [[ -z "$id" ]] || die "unexpected argument: $1"
        id="$1"
        shift
        ;;
    esac
  done

  cur_repo="$(repo_top)"
  if [[ -n "$id" ]]; then
    dir="$(job_dir "$id")"
    [[ -d "$dir" ]] || die "unknown job id: $id"
    job_repo="$(jq -r .repo "$dir/meta.json" 2>/dev/null || echo "")"
    [[ "$job_repo" == "$cur_repo" ]] || die "job repository ($job_repo) does not match current repository ($cur_repo)"
    for f in "$dir"/review-*.meta.json; do
      [[ -e "$f" ]] || continue
      out+="$(review_list_entry "$f" "$cur_repo")"$'\n'
    done
  else
    for f in "$(jobs_dir)"/*/review-*.meta.json "$(state_root)"/reviews/*/review.meta.json; do
      [[ -e "$f" ]] || continue
      out+="$(review_list_entry "$f" "$cur_repo")"$'\n'
    done
  fi
  printf '%s' "$out" | jq -sc 'sort_by([.created_at, .id]) | reverse'
}
