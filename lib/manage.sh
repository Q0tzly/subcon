# Listing, diffing, applying and discarding jobs (ticket 06).

cmd_list() {
  local all=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        all=1
        shift
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        die "unexpected argument: $1"
        ;;
    esac
  done

  local cur_repo=""
  if [[ $all -eq 0 ]]; then
    cur_repo="$(repo_top)" || return 1
  fi

  local base_dir
  base_dir="$(jobs_dir)"
  if [[ ! -d "$base_dir" ]]; then
    echo "[]"
    return 0
  fi

  local items=()
  local d
  for d in "$base_dir"/*; do
    [[ -d "$d" ]] || continue
    local id
    id="$(basename "$d")"
    local meta="$d/meta.json"
    [[ -f "$meta" ]] || continue

    if [[ $all -eq 0 ]]; then
      local r
      r="$(jq -r .repo "$meta" 2>/dev/null || echo "")"
      [[ "$r" == "$cur_repo" ]] || continue
    fi

    local res rc=0
    res="$(job_result "$id" 2>/dev/null)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      continue
    fi

    local created_at
    created_at="$(jq -r .created_at "$meta" 2>/dev/null || echo "")"

    local item
    item="$(jq -cn \
      --argjson r "$res" \
      --arg ca "$created_at" \
      '{
        id: $r.id,
        repo: $r.repo,
        ticket: $r.ticket,
        state: $r.state,
        status: $r.status,
        created_at: (if $ca == "" then null else $ca end)
      }')"
    items+=("$item")
  done

  if [[ ${#items[@]} -eq 0 ]]; then
    echo "[]"
    return 0
  fi

  printf '%s\n' "${items[@]}" | jq -sc 'sort_by([.created_at, .id]) | reverse'
}

cmd_diff() {
  [[ $# -eq 1 && -n "$1" ]] || die "job id required"

  local id="$1"
  local dir
  dir="$(job_dir "$id")"
  if [[ ! -d "$dir" ]]; then
    echo "subcon: unknown job id: $id" >&2
    return 1
  fi

  job_result "$id" >/dev/null 2>&1 || return 1

  local patch="$dir/patch.diff"
  if [[ ! -f "$patch" ]]; then
    echo "subcon: no patch for job: $id" >&2
    return 1
  fi

  cat "$patch"
}

cmd_log() {
  [[ $# -eq 1 && -n "$1" ]] || die "job id required"

  local id="$1"
  local dir
  dir="$(job_dir "$id")"
  if [[ ! -d "$dir" ]]; then
    echo "subcon: unknown job id: $id" >&2
    return 1
  fi

  local log="$dir/log"
  if [[ ! -f "$log" ]]; then
    echo "subcon: no log for job: $id" >&2
    return 1
  fi

  cat "$log"
}

cmd_apply() {
  [[ $# -eq 1 && -n "$1" ]] || die "job id required"

  local id="$1"
  local dir
  dir="$(job_dir "$id")"
  if [[ ! -d "$dir" ]]; then
    echo "subcon: unknown job id: $id" >&2
    return 1
  fi

  local cur_repo
  cur_repo="$(repo_top)" || return 1

  # Step 1: Check repo matches current repo top
  local job_repo
  job_repo="$(jq -r .repo "$dir/meta.json" 2>/dev/null || echo "")"
  if [[ "$job_repo" != "$cur_repo" ]]; then
    echo "subcon: job repository ($job_repo) does not match current repository ($cur_repo)" >&2
    return 1
  fi

  # Step 2: Determine state via job_result
  local res rc=0
  res="$(job_result "$id")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    return 1
  fi

  local state
  state="$(jq -r .state <<<"$res")"
  local patch="$dir/patch.diff"

  if [[ "$state" != "finished" && ! -f "$patch" ]]; then
    echo "subcon: job $id is not finished and has no patch" >&2
    return 1
  fi
  if [[ ! -f "$patch" ]]; then
    echo "subcon: job $id has no patch" >&2
    return 1
  fi

  # Step 3: git apply --check patch.diff
  # From the repo top: in a subdirectory git apply silently skips paths outside it.
  if [[ -s "$patch" ]]; then
    if ! git -C "$cur_repo" apply --check "$patch" 2>/dev/null; then
      echo "subcon: patch does not apply cleanly" >&2
      return 1
    fi

    # Step 4: git apply patch.diff (without touching index)
    if ! git -C "$cur_repo" apply "$patch"; then
      echo "subcon: failed to apply patch" >&2
      return 1
    fi
  fi

  ( history_append_event "$id" applied ) || echo "subcon: failed to record history for $id" >&2
  json_out '{id: $id, applied: true}' --arg id "$id"
}

cmd_commit() {
  local message=""
  local message_set=0
  local edited=0
  local id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m)
        [[ $# -ge 2 ]] || die "-m requires a value"
        message="$2"
        message_set=1
        shift 2
        ;;
      --edited)
        edited=1
        shift
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z "$id" ]]; then
          id="$1"
          shift
        else
          die "unexpected argument: $1"
        fi
        ;;
    esac
  done

  # Step 1: Check id is provided, job exists, and repo matches current repo
  [[ -n "$id" ]] || die "job id required"

  local dir
  dir="$(job_dir "$id")"
  if [[ ! -d "$dir" ]]; then
    echo "subcon: unknown job id: $id" >&2
    return 1
  fi

  local cur_repo
  cur_repo="$(repo_top)" || return 1

  local job_repo
  job_repo="$(jq -r .repo "$dir/meta.json" 2>/dev/null || echo "")"
  if [[ "$job_repo" != "$cur_repo" ]]; then
    echo "subcon: job repository ($job_repo) does not match current repository ($cur_repo)" >&2
    return 1
  fi

  # Step 2: SUBCON_REVIEWER check
  if [[ -z "${SUBCON_REVIEWER:-}" ]]; then
    die "SUBCON_REVIEWER is not set (e.g. SUBCON_REVIEWER='Name <email>')"
  fi

  # Step 3: -m check
  if [[ $message_set -eq 0 || -z "$message" ]]; then
    die "-m <message> required"
  fi

  # Step 4: Early checks before any side effects
  require_agy

  # Guard: double commit check
  local hfile
  hfile="$(history_file)"
  if [[ -f "$hfile" ]] && jq -se --arg id "$id" 'any(.type == "event" and .id == $id and .event == "committed")' "$hfile" >/dev/null 2>&1; then
    echo "subcon: job $id already committed" >&2
    return 1
  fi

  # Step 5: job_result state: finished, checks not null, checks.ok == true, checks.files_changed not empty
  local res rc=0
  res="$(job_result "$id")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    return 1
  fi

  local state
  state="$(jq -r .state <<<"$res")"
  if [[ "$state" != "finished" ]]; then
    echo "subcon: job $id is not finished (state: $state)" >&2
    return 1
  fi

  local has_checks
  has_checks="$(jq -r 'if .checks == null then "no" else "yes" end' <<<"$res")"
  if [[ "$has_checks" != "yes" ]]; then
    echo "subcon: job $id has no checks" >&2
    return 1
  fi

  local ok
  ok="$(jq -r '.checks.ok // false' <<<"$res")"
  if [[ "$ok" != "true" ]]; then
    echo "subcon: job $id checks failed" >&2
    return 1
  fi

  local files_len
  files_len="$(jq -r '.checks.files_changed | length' <<<"$res")"
  if [[ "$files_len" -eq 0 ]]; then
    echo "subcon: job $id has no changed files" >&2
    return 1
  fi

  # Guard: patch applied check (unless --edited)
  if [[ $edited -eq 0 ]]; then
    local patch="$dir/patch.diff"
    if [[ ! -f "$patch" ]] || ! git -C "$cur_repo" apply --check --reverse "$patch" >/dev/null 2>&1; then
      echo "subcon: patch not applied for job $id (apply it first or pass --edited)" >&2
      return 1
    fi
  fi

  # Resolve implementer before staging
  local model
  model="$(jq -r .model "$dir/meta.json" 2>/dev/null || echo "")"
  local implementer
  implementer="$(model_name "$model")"
  [[ -n "$implementer" ]] || die "unknown model: $model (see: agy models)"

  # Step 6: Stage only checks.files_changed via git -C <repo> add -A -- <paths...>
  local files=()
  local f
  while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -n "$f" ]] && files+=("$f")
  done < <(jq -r '.checks.files_changed[]' <<<"$res")

  if ! git -C "$cur_repo" add -A -- "${files[@]}"; then
    echo "subcon: failed to stage files" >&2
    return 1
  fi

  if git -C "$cur_repo" diff --cached --quiet -- "${files[@]}"; then
    echo "subcon: no staged changes to commit for job $id (not applied or already committed)" >&2
    return 1
  fi

  # Step 7: Commit
  local commit_msg
  commit_msg="$message

Co-Authored-By: $implementer <$SUBCON_COAUTHOR_EMAIL>"
  if [[ $edited -eq 1 ]]; then
    commit_msg="$commit_msg
Co-Authored-By: $SUBCON_REVIEWER"
  fi
  commit_msg="$commit_msg
Reviewed-By: $SUBCON_REVIEWER"

  if ! git -C "$cur_repo" commit -q -m "$commit_msg" >/dev/null; then
    echo "subcon: commit failed" >&2
    return 1
  fi

  # Step 8: Record history event and output JSON
  local commit_hash
  commit_hash="$(git -C "$cur_repo" rev-parse HEAD)"

  ( history_append_event "$id" committed ) || echo "subcon: failed to record history for $id" >&2
  json_out '{id: $id, commit: $commit}' --arg id "$id" --arg commit "$commit_hash"
}

cmd_reject() {
  local reason=""
  local reason_set=0
  local model=""
  local runner=""
  local id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m)
        [[ $# -ge 2 ]] || die "-m requires a value"
        reason="$2"
        reason_set=1
        shift 2
        ;;
      --model)
        [[ $# -ge 2 ]] || die "--model requires a value"
        model="$2"
        shift 2
        ;;
      --runner)
        [[ $# -ge 2 ]] || die "--runner requires a value"
        runner="$2"
        shift 2
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z "$id" ]]; then
          id="$1"
          shift
        else
          die "unexpected argument: $1"
        fi
        ;;
    esac
  done

  # Step 1: Check id is provided, job exists, and repo matches current repo
  [[ -n "$id" ]] || die "job id required"

  local dir
  dir="$(job_dir "$id")"
  if [[ ! -d "$dir" ]]; then
    echo "subcon: unknown job id: $id" >&2
    return 1
  fi

  local cur_repo
  cur_repo="$(repo_top)" || return 1

  local job_repo
  job_repo="$(jq -r .repo "$dir/meta.json" 2>/dev/null || echo "")"
  if [[ "$job_repo" != "$cur_repo" ]]; then
    echo "subcon: job repository ($job_repo) does not match current repository ($cur_repo)" >&2
    return 1
  fi

  # Step 2: -m check
  if [[ $reason_set -eq 0 || -z "$reason" ]]; then
    die "-m <reason> required"
  fi

  # Step 3: job_result state: finished check
  local res rc=0
  res="$(job_result "$id")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    return 1
  fi

  local state
  state="$(jq -r .state <<<"$res")"
  if [[ "$state" != "finished" ]]; then
    echo "subcon: job $id is not finished (state: $state)" >&2
    return 1
  fi

  # Step 4: Pre-flight checks before any side effects
  require_agy

  local orig_runner orig_model
  orig_runner="$(jq -r .runner "$dir/meta.json" 2>/dev/null || echo "")"
  orig_model="$(jq -r .model "$dir/meta.json" 2>/dev/null || echo "")"

  local effective_runner="${runner:-$orig_runner}"
  local effective_model="${model:-$orig_model}"

  [[ -f "$SUBCON_ROOT/runners/$effective_runner" && -x "$SUBCON_ROOT/runners/$effective_runner" ]] || die "runner not found: $effective_runner"
  if [[ "$effective_runner" == "container" ]]; then
    require_container
  fi
  if [[ "$effective_runner" == "ci" ]]; then
    require_ci "$cur_repo"
  fi

  # Step 5: Delegation limit check: count only initial delegations for repo and ticket (ignore jobs created by resume)
  local ticket
  ticket="$(jq -r .ticket "$dir/meta.json")"

  local hfile
  hfile="$(history_file)"
  local count=0
  if [[ -f "$hfile" ]]; then
    count="$(jq -sr --arg repo "$cur_repo" --arg ticket "$ticket" '
      map(select(.type == "job" and .repo == $repo and .ticket == $ticket and (.resume_of == null))) | length
    ' "$hfile" 2>/dev/null || echo 0)"
  fi
  if [[ "$count" -ge 3 ]]; then
    echo "subcon: delegation limit reached (already delegated $count times for $ticket)" >&2
    return 1
  fi

  # Step 6: Ticket file exists and clean check
  local ticket_path="$cur_repo/$ticket"
  if [[ ! -f "$ticket_path" ]]; then
    echo "subcon: ticket file not found: $ticket" >&2
    return 1
  fi

  if [[ -n "$(git -C "$cur_repo" status --porcelain -- "$ticket" 2>/dev/null)" ]]; then
    echo "subcon: ticket file has uncommitted changes: $ticket" >&2
    return 1
  fi

  # Step 6: Append reject line to ticket
  if ! JOB_ID="$id" REASON="$reason" awk '
    /^## Notes([[:space:]]|$)/ {
      found_notes = 1
      in_notes = 1
      print
      next
    }
    in_notes && /^## / {
      print "- 差し戻し（job " ENVIRON["JOB_ID"] "）: " ENVIRON["REASON"]
      if (blanks != "") { printf "%s", blanks; blanks = "" }
      in_notes = 0
      inserted = 1
      print
      next
    }
    in_notes {
      if ($0 ~ /^[[:space:]]*$/) {
        blanks = blanks $0 "\n"
        next
      } else {
        if (blanks != "") { printf "%s", blanks; blanks = "" }
        print
        next
      }
    }
    {
      last_line = $0
      print
    }
    END {
      if (!found_notes) {
        if (NR > 0 && last_line !~ /^[[:space:]]*$/) print ""
        print "## Notes"
        print "- 差し戻し（job " ENVIRON["JOB_ID"] "）: " ENVIRON["REASON"]
      } else if (in_notes && !inserted) {
        print "- 差し戻し（job " ENVIRON["JOB_ID"] "）: " ENVIRON["REASON"]
        if (blanks != "") printf "%s", blanks
      }
    }
  ' "$ticket_path" | atomic_write "$ticket_path"; then
    echo "subcon: failed to update ticket file" >&2
    return 1
  fi

  # Step 8: Commit ticket file only
  if ! git -C "$cur_repo" add -- "$ticket"; then
    echo "subcon: failed to stage ticket" >&2
    return 1
  fi

  local commit_msg
  commit_msg="$(printf 'reject: %s\n\n%s\n' "$ticket" "$reason")"
  if ! git -C "$cur_repo" commit -q -m "$commit_msg"; then
    echo "subcon: commit failed" >&2
    return 1
  fi

  # Step 9: Record rejected history event
  ( history_append_event "$id" rejected ) || echo "subcon: failed to record history for $id" >&2

  # Step 10: Launch new job with cmd_submit
  local submit_out submit_rc=0
  submit_out="$(cmd_submit --runner "$effective_runner" --model "$effective_model" "$ticket")" || submit_rc=$?

  local new_id=""
  if [[ $submit_rc -eq 0 && -n "$submit_out" ]]; then
    new_id="$(jq -r '.[0].id // empty' <<<"$submit_out" 2>/dev/null || echo "")"
  fi

  if [[ $submit_rc -eq 0 && -n "$new_id" && "$new_id" != "null" ]]; then
    json_out '{id: $id, reject_of: $old, ticket: $ticket, error: null}' \
      --arg id "$new_id" \
      --arg old "$id" \
      --arg ticket "$ticket"
    return 0
  else
    local err
    err="$(jq -r '.[0].error // empty' <<<"$submit_out" 2>/dev/null || echo "")"
    [[ -n "$err" ]] || err="failed to submit job"
    json_out '{id: null, reject_of: $old, ticket: $ticket, error: $err}' \
      --arg old "$id" \
      --arg ticket "$ticket" \
      --arg err "$err"
    return 4
  fi
}

cmd_discard() {
  [[ $# -gt 0 ]] || die "at least one job id required"

  local id
  for id in "$@"; do
    [[ -n "$id" ]] || die "job id cannot be empty"
    local d
    d="$(job_dir "$id")"
    if [[ ! -d "$d" ]]; then
      echo "subcon: unknown job id: $id" >&2
      return 1
    fi
  done

  for id in "$@"; do
    local dir
    dir="$(job_dir "$id")"
    [[ -d "$dir" ]] || continue

    local pid=""
    if [[ -f "$dir/pid" ]]; then
      pid="$(cat "$dir/pid" 2>/dev/null || echo "")"
    fi

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
      local waited=0
      while kill -0 "$pid" 2>/dev/null && (( waited < 50 )); do
        sleep 0.1
        waited=$((waited + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        pkill -9 -P "$pid" 2>/dev/null || true
        kill -9 "$pid" 2>/dev/null || true
      fi
    fi

    local repo=""
    if [[ -f "$dir/meta.json" ]]; then
      repo="$(jq -r .repo "$dir/meta.json" 2>/dev/null || echo "")"
    fi

    if [[ -e "$dir/work" ]]; then
      if [[ -n "$repo" && -d "$repo" ]]; then
        git -C "$repo" worktree remove --force "$dir/work" 2>/dev/null || {
          rm -rf "$dir/work"
          git -C "$repo" worktree prune 2>/dev/null || true
        }
      else
        rm -rf "$dir/work"
      fi
    fi

    rm -rf "$dir"
  done

  jq -cn --args '{discarded: $ARGS.positional}' "$@"
}
