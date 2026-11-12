# Job creation, background execution and finalization (ticket 04).

cmd_submit() {
  local runner="local"
  local driver="${SUBCON_DRIVER:-agy}"
  local model=""
  local timeout="$SUBCON_DEFAULT_TIMEOUT"
  local issue_raw=""
  local issue_set=0
  local tickets=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runner)
        [[ $# -ge 2 ]] || die "--runner requires a value"
        runner="$2"
        shift 2
        ;;
      --model)
        [[ $# -ge 2 ]] || die "--model requires a value"
        model="$2"
        shift 2
        ;;
      --driver)
        [[ $# -ge 2 ]] || die "--driver requires a value"
        driver="$2"
        shift 2
        ;;
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires a value"
        timeout="$2"
        shift 2
        ;;
      --issue)
        [[ $# -ge 2 ]] || die "--issue requires a value"
        issue_raw="$2"
        issue_set=1
        shift 2
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        tickets+=("$1")
        shift
        ;;
    esac
  done

  # Validate options
  require_driver "$driver"
  if [[ "$driver" == agy ]]; then
    warn_consumer_auth
  fi
  [[ -n "$model" ]] || model="$(default_model "$driver")"
  [[ -f "$SUBCON_ROOT/runners/$runner" && -x "$SUBCON_ROOT/runners/$runner" ]] || die "runner not found: $runner"
  [[ ${#tickets[@]} -gt 0 ]] || die "at least one ticket required"

  if [[ "$runner" == "ci" ]]; then
    case "$driver" in
      agy|claude) ;;
      *) die "the ci runner supports the agy and claude drivers only" ;;
    esac
  fi

  if [[ "$runner" == "container" ]]; then
    case "$driver" in
      agy) ;;
      claude)
        [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "the container runner with the claude driver requires ANTHROPIC_API_KEY"
        ;;
      *) die "the container runner supports the agy and claude drivers only" ;;
    esac
    require_container
  fi

  local repo
  repo="$(repo_top)"

  local issue_json=""
  if [[ $issue_set -eq 1 ]]; then
    issue_json="$(issue_ref_json "$issue_raw" "$repo")" || die "invalid issue reference: $issue_raw"
  fi

  if [[ "$runner" == "ci" ]]; then
    require_ci "$repo"
  fi

  # Monthly budget caps. An empty value counts as unset; resume does not check them.
  if [[ -n "${SUBCON_BUDGET_TOKENS:-}" ]]; then
    [[ "$SUBCON_BUDGET_TOKENS" =~ ^[0-9]+$ ]] || die "invalid SUBCON_BUDGET_TOKENS: $SUBCON_BUDGET_TOKENS (must be a non-negative integer)"
  fi
  if [[ -n "${SUBCON_BUDGET_JOBS:-}" ]]; then
    [[ "$SUBCON_BUDGET_JOBS" =~ ^[0-9]+$ ]] || die "invalid SUBCON_BUDGET_JOBS: $SUBCON_BUDGET_JOBS (must be a non-negative integer)"
  fi
  if [[ -n "${SUBCON_BUDGET_TOKENS:-}" || -n "${SUBCON_BUDGET_JOBS:-}" ]]; then
    local budget_month budget_usage used_jobs used_tokens
    budget_month="$(date -u +%Y-%m)"
    budget_usage="$(history_month_usage)"
    used_jobs="$(jq -r .jobs <<<"$budget_usage")"
    used_tokens="$(jq -r .tokens <<<"$budget_usage")"
    if [[ -n "${SUBCON_BUDGET_TOKENS:-}" && "$used_tokens" -ge "$SUBCON_BUDGET_TOKENS" ]]; then
      die "monthly token budget reached: $used_tokens >= SUBCON_BUDGET_TOKENS=$SUBCON_BUDGET_TOKENS (UTC month $budget_month)"
    fi
    if [[ -n "${SUBCON_BUDGET_JOBS:-}" && "$used_jobs" -ge "$SUBCON_BUDGET_JOBS" ]]; then
      die "monthly job budget reached: $used_jobs >= SUBCON_BUDGET_JOBS=$SUBCON_BUDGET_JOBS (UTC month $budget_month)"
    fi
  fi

  # Step 1: Validate all tickets upfront. If any fails, exit 1 without creating any job.
  local t
  for t in "${tickets[@]}"; do
    ticket_validate "$t" || return 1
  done

  # Step 2: Warn if working tree has uncommitted changes.
  if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
    echo "subcon: warning: working tree has uncommitted changes (jobs will run from HEAD)" >&2
  fi

  local base
  base="$(git rev-parse HEAD)"

  local submit_results=()
  local has_failure=0

  # Step 3: For each ticket, create the job and launch its runner in the background.
  for t in "${tickets[@]}"; do
    if job_create "$repo" "$t" "$base" "$runner" "$model" "$timeout" "" "$driver" "$issue_json"; then
      job_warn_overlap "$JOB_ID" "$t" "$repo"
      submit_results+=("$(json_out '{ticket: $t, id: $id, error: null}' --arg t "$t" --arg id "$JOB_ID")")
    else
      submit_results+=("$(json_out '{ticket: $t, id: null, error: $err}' --arg t "$t" --arg err "$JOB_ERR")")
      has_failure=1
    fi
  done

  # Print JSON array to stdout
  printf '%s\n' "${submit_results[@]}" | jq -sc .

  if [[ $has_failure -ne 0 ]]; then
    return 4
  fi
  return 0
}

# job_warn_overlap <job-id> <ticket> <repo>
# Warns on stderr for each queued/running job (other than <job-id>) in <repo> whose
# ## Files share a path with the ticket. Paths are repo-relative, so jobs from other
# repositories are skipped; a job whose meta.json is unreadable or has no repo is skipped too.
# Advisory only: never changes the exit status.
job_warn_overlap() {
  local id="$1" rel_ticket="$2" repo="$3"
  local own_files other_dir other other_state other_repo other_files common f

  own_files="$(ticket_files "$(job_dir "$id")/ticket.md")"

  for other_dir in "$(jobs_dir)"/*/; do
    [[ -d "$other_dir" ]] || continue
    other="$(basename "$other_dir")"
    [[ "$other" != "$id" ]] || continue

    other_state="$(cat "$other_dir/state" 2>/dev/null || echo "")"
    if [[ "$other_state" != queued && "$other_state" != running ]]; then
      continue
    fi
    other_repo="$(jq -r '.repo // empty' "$other_dir/meta.json" 2>/dev/null || echo "")"
    [[ "$other_repo" == "$repo" ]] || continue
    [[ -f "$other_dir/ticket.md" ]] || continue
    other_files="$(ticket_files "$other_dir/ticket.md")"

    common=""
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if grep -Fxq -- "$f" <<<"$other_files"; then
        common="${common:+$common, }$f"
      fi
    done <<<"$own_files"

    if [[ -n "$common" ]]; then
      echo "subcon: warning: $rel_ticket overlaps with active job $other on: $common" >&2
    fi
  done
}

# job_create <repo> <ticket> <base> <runner> <model> <timeout> <from-job-dir> <driver> [issue-json]
# Creates a job directory with its worktree and starts the runner in the background.
# Sets JOB_ID on success and JOB_ERR on failure (nothing is left behind on failure).
# With <from-job-dir> (resume), the ticket and the carried-over patch come from that
# job instead of HEAD, and meta.json records resume_of and the conversation to continue.
# An empty <driver> means agy (jobs created before drivers existed).
job_create() {
  local repo="$1" rel_ticket="$2" base="$3" runner="$4" model="$5" timeout="$6" from_dir="${7:-}" driver="${8:-agy}" issue_json="${9:-}"
  JOB_ID="" JOB_ERR=""

  local ticket_base
  ticket_base="$(basename "$rel_ticket" .md)"
  local jobs_base
  jobs_base="$(jobs_dir)"
  mkdir -p "$jobs_base" || { JOB_ERR="failed to create $jobs_base"; return 1; }

  # Try up to 5 times to create an exclusive job directory
  local job_id="" job_path="" i
  for ((i = 0; i < 5; i++)); do
    local ts rand cand_id cand_path
    ts="$(date +%Y%m%d-%H%M%S)"
    rand="$(printf '%02x%02x' "$((RANDOM % 256))" "$((RANDOM % 256))")"
    cand_id="${ts}-${ticket_base}-${rand}"
    cand_path="${jobs_base}/${cand_id}"
    if mkdir "$cand_path" 2>/dev/null; then
      job_id="$cand_id"
      job_path="$cand_path"
      break
    fi
  done
  if [[ -z "$job_id" ]]; then
    JOB_ERR="failed to create unique job directory"
    return 1
  fi

  local err_msg=""
  local created_at
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local resume_of="" conversation=""
  if [[ -n "$from_dir" ]]; then
    resume_of="$(jq -r .id "$from_dir/meta.json")"
    conversation="$(jq -r '.conversation // empty' "$from_dir/result.json")"
    issue_json="$(jq -c '.issue // empty' "$from_dir/meta.json" 2>/dev/null || echo "")"
  fi

  if ! json_out '{v: 1, id: $id, repo: $repo, ticket: $ticket, base: $base, runner: $runner, driver: $driver, model: $model, timeout: $timeout, created_at: $created_at}
      + (if $resume_of == "" then {} else {resume_of: $resume_of, conversation: $conversation} end)
      + (if $issue == "" then {} else {issue: ($issue | fromjson)} end)' \
    --arg id "$job_id" \
    --arg repo "$repo" \
    --arg ticket "$rel_ticket" \
    --arg base "$base" \
    --arg runner "$runner" \
    --arg driver "$driver" \
    --arg model "$model" \
    --arg timeout "$timeout" \
    --arg created_at "$created_at" \
    --arg resume_of "$resume_of" \
    --arg conversation "$conversation" \
    --arg issue "$issue_json" | atomic_write "$job_path/meta.json"; then
    err_msg="failed to write meta.json"
  fi

  if [[ -z "$err_msg" ]]; then
    if [[ -n "$from_dir" ]]; then
      cp "$from_dir/ticket.md" "$job_path/ticket.md" 2>/dev/null || err_msg="failed to write ticket.md"
    else
      git show "HEAD:$rel_ticket" > "$job_path/ticket.md" 2>/dev/null || err_msg="failed to write ticket.md"
    fi
  fi

  if [[ -z "$err_msg" ]]; then
    echo "queued" | atomic_write "$job_path/state" || err_msg="failed to write state"
  fi

  if [[ -z "$err_msg" ]]; then
    if [[ "$runner" == "container" ]]; then
      git clone -q "$repo" "$job_path/work" >/dev/null 2>&1 && \
        git -C "$job_path/work" checkout -q "$base" >/dev/null 2>&1 || \
        err_msg="failed to create worktree"
    else
      git -C "$repo" worktree add --detach "$job_path/work" "$base" >/dev/null 2>&1 || err_msg="failed to create worktree"
    fi
  fi

  # Carry the interrupted run's work over, so the agent continues instead of redoing it.
  if [[ -z "$err_msg" && -n "$from_dir" && -s "$from_dir/patch.diff" ]]; then
    git -C "$job_path/work" apply --binary "$from_dir/patch.diff" 2>/dev/null || err_msg="failed to apply the previous patch"
  fi

  if [[ -z "$err_msg" ]]; then
    local pid
    if nohup "$SUBCON_ROOT/bin/subcon" __exec "$job_path" >/dev/null 2>&1 & then
      pid=$!
      echo "$pid" > "$job_path/pid"
    else
      err_msg="failed to launch runner"
    fi
  fi

  if [[ -n "$err_msg" ]]; then
    if [[ -d "$job_path/work" ]]; then
      git -C "$repo" worktree remove --force "$job_path/work" 2>/dev/null || {
        rm -rf "$job_path/work"
        git -C "$repo" worktree prune 2>/dev/null || true
      }
    fi
    rm -rf "$job_path"
    JOB_ERR="$err_msg"
    return 1
  fi

  JOB_ID="$job_id"
}

cmd_resume() {
  local timeout="" id=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires a value"
        timeout="$2"
        shift 2
        ;;
      -*) die "unknown option: $1" ;;
      *)
        [[ -z "$id" ]] || die "resume takes one job id"
        id="$1"
        shift
        ;;
    esac
  done
  [[ -n "$id" ]] || die "job id required"

  local dir
  dir="$(job_dir "$id")"
  [[ -d "$dir" ]] || die "unknown job id: $id"

  local driver
  driver="$(jq -r '.driver // "agy"' "$dir/meta.json")"
  require_driver "$driver"
  if [[ "$driver" == agy ]]; then
    warn_consumer_auth
  fi

  local repo
  repo="$(repo_top)"
  [[ "$(jq -r .repo "$dir/meta.json")" == "$repo" ]] || die "job $id belongs to another repository"

  local runner
  runner="$(jq -r .runner "$dir/meta.json")"
  [[ "$runner" != "ci" ]] || die "resume is not supported for the ci runner"

  # job_result settles a job whose runner vanished, so a killed job becomes failed first.
  job_result "$id" >/dev/null || true
  [[ "$(cat "$dir/state" 2>/dev/null)" == "failed" ]] || die "job $id is not failed (only failed jobs can be resumed)"
  [[ -n "$(jq -r '.conversation // empty' "$dir/result.json")" ]] || die "job $id has no conversation to resume (agy wrote no conversation_id)"

  local ticket base model
  ticket="$(jq -r .ticket "$dir/meta.json")"
  base="$(jq -r .base "$dir/meta.json")"
  model="$(jq -r .model "$dir/meta.json")"
  [[ -n "$timeout" ]] || timeout="$(jq -r .timeout "$dir/meta.json")"

  if [[ "$runner" == "container" ]]; then
    if [[ "$driver" == claude ]]; then
      [[ -n "${ANTHROPIC_API_KEY:-}" ]] || die "the container runner with the claude driver requires ANTHROPIC_API_KEY"
    fi
    require_container
  fi

  local result rc=0
  if job_create "$repo" "$ticket" "$base" "$runner" "$model" "$timeout" "$dir" "$driver"; then
    result="$(json_out '{ticket: $t, id: $id, resume_of: $of, error: null}' --arg t "$ticket" --arg id "$JOB_ID" --arg of "$id")"
  else
    result="$(json_out '{ticket: $t, id: null, resume_of: $of, error: $err}' --arg t "$ticket" --arg err "$JOB_ERR" --arg of "$id")"
    rc=4
  fi
  printf '%s\n' "$result" | jq -sc .
  return "$rc"
}

job_exec() {
  local job_dir="${1:-}"
  [[ -n "$job_dir" && -d "$job_dir" ]] || die "job directory not found: $job_dir"
  [[ "$job_dir" = /* ]] || job_dir="$(pwd)/$job_dir"

  local runner_rc="died"
  local finalized=0

  _trap_handler() {
    if [[ $finalized -eq 0 ]]; then
      finalized=1
      job_finalize "$job_dir" "$runner_rc"
    fi
  }

  trap '_trap_handler' EXIT INT TERM HUP

  # 1. state=running
  local current_state
  current_state="$(cat "$job_dir/state" 2>/dev/null || echo "")"
  if [[ "$current_state" == "queued" ]]; then
    echo "running" | atomic_write "$job_dir/state"
  fi

  # 2. Run runner
  local runner model timeout driver
  runner="$(jq -r .runner "$job_dir/meta.json")"
  model="$(jq -r .model "$job_dir/meta.json")"
  timeout="$(jq -r .timeout "$job_dir/meta.json")"
  # Jobs created before meta.json recorded the driver ran agy.
  driver="$(jq -r '.driver // "agy"' "$job_dir/meta.json")"

  local prompt_file="$job_dir/prompt.txt"
  local conversation
  conversation="$(jq -r '.conversation // empty' "$job_dir/meta.json")"
  if [[ -n "$conversation" ]]; then
    # The conversation already holds the ticket and the rules; only say what changed.
    cp "$SUBCON_RESUME_PROMPT" "$prompt_file"
    export SUBCON_CONVERSATION="$conversation"
  else
    unset SUBCON_CONVERSATION
    cat "$SUBCON_PROMPT_PREAMBLE" "$job_dir/ticket.md" > "$prompt_file"
  fi

  export SUBCON_PROMPT_FILE="$prompt_file"
  export SUBCON_JOB_MODEL="$model"
  export SUBCON_TIMEOUT="$timeout"
  export SUBCON_SCHEMA="$SUBCON_SCHEMA"
  export SUBCON_DRIVER="$driver"

  local runner_bin="$SUBCON_ROOT/runners/$runner"
  if [[ ! -x "$runner_bin" ]]; then
    echo "runner not executable: $runner_bin" >> "$job_dir/log"
    runner_rc=1
  else
    # Run in the background and `wait`: bash defers traps until a foreground
    # child exits, so a TERM from `discard` would otherwise wait for agy.
    local rc=0 runner_pid
    "$runner_bin" "$job_dir" 2>> "$job_dir/log" &
    runner_pid=$!
    trap 'pkill -TERM -P "$runner_pid" 2>/dev/null; kill -TERM "$runner_pid" 2>/dev/null; exit 143' INT TERM HUP
    wait "$runner_pid" || rc=$?
    runner_rc="$rc"
  fi

  # 3. Finalize
  finalized=1
  trap - EXIT INT TERM HUP
  job_finalize "$job_dir" "$runner_rc"
}

job_finalize() {
  local job_dir="${1:-}"
  local runner_code="${2:-1}"
  [[ -n "$job_dir" && -d "$job_dir" ]] || return 1
  [[ "$job_dir" = /* ]] || job_dir="$(pwd)/$job_dir"

  # state transition check: state only progresses queued -> running -> finished/failed
  local current_state
  current_state="$(cat "$job_dir/state" 2>/dev/null || echo "")"
  if [[ "$current_state" == "finished" || "$current_state" == "failed" ]]; then
    return 0
  fi

  local id repo ticket base issue="null"
  id="$(jq -r .id "$job_dir/meta.json")"
  repo="$(jq -r .repo "$job_dir/meta.json")"
  ticket="$(jq -r .ticket "$job_dir/meta.json")"
  base="$(jq -r .base "$job_dir/meta.json")"
  if [[ -f "$job_dir/meta.json" ]]; then
    issue="$(jq -c '.issue // null' "$job_dir/meta.json" 2>/dev/null || echo "null")"
  fi

  local work_dir="$job_dir/work"
  local has_patch=0
  local checks="null"
  local diffstat=""

  # 1. work/ があれば: git -C work add -A → git -C work diff --cached --binary <base> を patch.diff へ → チェック
  if [[ -d "$work_dir" ]]; then
    if git -C "$work_dir" add -A 2>/dev/null; then
      if git -C "$work_dir" diff --cached --binary "$base" > "$job_dir/patch.diff" 2>/dev/null; then
        has_patch=1
        diffstat="$(git -C "$work_dir" diff --cached --shortstat "$base" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

        local current_head committed=false
        current_head="$(git -C "$work_dir" rev-parse HEAD 2>/dev/null || echo "")"
        if [[ -n "$current_head" && "$current_head" != "$base" ]]; then
          committed=true
        fi

        local files_changed_json
        files_changed_json="$(git -C "$work_dir" diff --cached --name-only "$base" 2>/dev/null | jq -Rnc '[inputs | select(length > 0)]')"

        local allowed_files_json
        allowed_files_json="$(ticket_files "$job_dir/ticket.md" | jq -Rnc '[inputs | select(length > 0)]')"

        checks="$(jq -cn \
          --argjson committed "$committed" \
          --argjson files "$files_changed_json" \
          --argjson allowed "$allowed_files_json" \
          '{
            ok: (($committed == false) and (($files - $allowed | length) == 0)),
            committed: $committed,
            outside_files: ($files - $allowed),
            files_changed: $files
          }')"
      fi
    fi
  fi

  # Determine state, error, report, status
  local final_state="finished"
  local error=""
  local report="null"
  local status=""

  if [[ "$runner_code" == "died" ]]; then
    final_state="failed"
    error="runner died"
  elif [[ "$runner_code" != "0" ]]; then
    final_state="failed"
    error="runner exited with $runner_code"
  else
    if [[ ! -f "$job_dir/agy.json" ]] || ! jq -e . "$job_dir/agy.json" >/dev/null 2>&1; then
      final_state="failed"
      error="agy output missing or invalid"
    fi
  fi

  if [[ "$final_state" == "finished" ]]; then
    if [[ -f "$job_dir/agy.json" ]] && jq -e '.structured_output | objects' "$job_dir/agy.json" >/dev/null 2>&1; then
      report="$(jq -c '.structured_output' "$job_dir/agy.json")"
      status="$(jq -r '.structured_output.status // empty' "$job_dir/agy.json")"
    fi
  fi

  # agy writes conversation_id even when it fails, which is what makes `resume` possible.
  local conversation="" agy_error=""
  if [[ -f "$job_dir/agy.json" ]] && jq -e . "$job_dir/agy.json" >/dev/null 2>&1; then
    conversation="$(jq -r '.conversation_id // empty' "$job_dir/agy.json")"
    agy_error="$(jq -r '.error // empty | if type == "string" then . else tojson end' "$job_dir/agy.json")"
  fi

  # 2. Write result.json
  jq -cn \
    --arg id "$id" \
    --arg repo "$repo" \
    --arg ticket "$ticket" \
    --arg state "$final_state" \
    --arg status "$status" \
    --arg error "$error" \
    --arg conversation "$conversation" \
    --arg agy_error "$agy_error" \
    --arg has_patch "$has_patch" \
    --arg patch "$job_dir/patch.diff" \
    --arg diffstat "$diffstat" \
    --argjson checks "$checks" \
    --argjson report "$report" \
    --argjson issue "$issue" \
    '{
      v: 1,
      id: $id,
      repo: $repo,
      ticket: $ticket,
      state: $state,
      status: (if $status == "" then null else $status end),
      checks: (if $has_patch == "1" then $checks else null end),
      report: $report,
      patch: (if $has_patch == "1" then $patch else null end),
      diffstat: (if $has_patch == "1" then $diffstat else null end),
      error: (if $error == "" then null else $error end),
      agy_error: (if $agy_error == "" then null else $agy_error end),
      conversation: (if $conversation == "" then null else $conversation end),
      issue: $issue
    }' | atomic_write "$job_dir/result.json"

  # Before the state update, so a finished state implies the history line exists.
  # In a subshell: history must never break finalization.
  ( history_append_job "$job_dir" ) || echo "subcon: failed to record history for $id" >&2

  # 3. Update state
  echo "$final_state" | atomic_write "$job_dir/state"

  # Remove worktree
  if [[ -d "$work_dir" ]]; then
    git -C "$repo" worktree remove --force "$work_dir" 2>/dev/null || {
      rm -rf "$work_dir"
      git -C "$repo" worktree prune 2>/dev/null || true
    }
  fi
}
