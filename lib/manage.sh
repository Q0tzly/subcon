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

  # Step 4: job_result state: finished, checks not null, checks.ok == true, checks.files_changed not empty
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

  # Step 5: Stage only checks.files_changed via git -C <repo> add -A -- <paths...>
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

  # Step 6: Commit
  local model
  model="$(jq -r .model "$dir/meta.json" 2>/dev/null || echo "")"
  local implementer
  implementer="$(model_name "$model")"
  [[ -n "$implementer" ]] || die "unknown model: $model (see: agy models)"

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

  # Step 7: Record history event and output JSON
  local commit_hash
  commit_hash="$(git -C "$cur_repo" rev-parse HEAD)"

  ( history_append_event "$id" committed ) || echo "subcon: failed to record history for $id" >&2
  json_out '{id: $id, commit: $commit}' --arg id "$id" --arg commit "$commit_hash"
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
