# Job creation, background execution and finalization (ticket 04).

cmd_submit() {
  local runner="local"
  local model
  model="$(default_model)"
  local timeout="$SUBCON_DEFAULT_TIMEOUT"
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
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires a value"
        timeout="$2"
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
  [[ -f "$SUBCON_ROOT/runners/$runner" && -x "$SUBCON_ROOT/runners/$runner" ]] || die "runner not found: $runner"
  [[ ${#tickets[@]} -gt 0 ]] || die "at least one ticket required"

  local repo
  repo="$(repo_top)"

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

  local jobs_base
  jobs_base="$(jobs_dir)"
  mkdir -p "$jobs_base"

  local submit_results=()
  local has_failure=0

  # Step 3: For each ticket, create job directory exclusively, meta.json, ticket.md, state=queued, work/ worktree, and launch runner in background.
  for t in "${tickets[@]}"; do
    local rel_ticket="$t"
    local ticket_base
    ticket_base="$(basename "$rel_ticket" .md)"

    # Try up to 5 times to create an exclusive job directory
    local job_id="" job_path="" created=0 i
    for ((i = 0; i < 5; i++)); do
      local ts rand cand_id cand_path
      ts="$(date +%Y%m%d-%H%M%S)"
      rand="$(printf '%02x%02x' "$((RANDOM % 256))" "$((RANDOM % 256))")"
      cand_id="${ts}-${ticket_base}-${rand}"
      cand_path="${jobs_base}/${cand_id}"
      if mkdir "$cand_path" 2>/dev/null; then
        job_id="$cand_id"
        job_path="$cand_path"
        created=1
        break
      fi
    done

    if [[ $created -eq 0 ]]; then
      submit_results+=("$(json_out '{ticket: $t, id: null, error: "failed to create unique job directory"}' --arg t "$rel_ticket")")
      has_failure=1
      continue
    fi

    local setup_ok=1
    local err_msg=""

    # Write meta.json
    local created_at
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! json_out '{id: $id, repo: $repo, ticket: $ticket, base: $base, runner: $runner, model: $model, timeout: $timeout, created_at: $created_at}' \
      --arg id "$job_id" \
      --arg repo "$repo" \
      --arg ticket "$rel_ticket" \
      --arg base "$base" \
      --arg runner "$runner" \
      --arg model "$model" \
      --arg timeout "$timeout" \
      --arg created_at "$created_at" | atomic_write "$job_path/meta.json"; then
      setup_ok=0
      err_msg="failed to write meta.json"
    fi

    # Write ticket.md
    if [[ $setup_ok -eq 1 ]]; then
      if ! git show "HEAD:$rel_ticket" > "$job_path/ticket.md" 2>/dev/null; then
        setup_ok=0
        err_msg="failed to write ticket.md"
      fi
    fi

    # Write state=queued
    if [[ $setup_ok -eq 1 ]]; then
      if ! echo "queued" | atomic_write "$job_path/state"; then
        setup_ok=0
        err_msg="failed to write state"
      fi
    fi

    # Create worktree
    if [[ $setup_ok -eq 1 ]]; then
      if ! git -C "$repo" worktree add --detach "$job_path/work" "$base" >/dev/null 2>&1; then
        setup_ok=0
        err_msg="failed to create worktree"
      fi
    fi

    # Launch background runner and write pid
    if [[ $setup_ok -eq 1 ]]; then
      local pid
      if nohup "$SUBCON_ROOT/bin/subcon" __exec "$job_path" >/dev/null 2>&1 & then
        pid=$!
        echo "$pid" > "$job_path/pid"
      else
        setup_ok=0
        err_msg="failed to launch runner"
      fi
    fi

    if [[ $setup_ok -eq 1 ]]; then
      submit_results+=("$(json_out '{ticket: $t, id: $id, error: null}' --arg t "$rel_ticket" --arg id "$job_id")")
    else
      # Step 4: Cleanup on failure
      if [[ -d "$job_path/work" ]]; then
        git -C "$repo" worktree remove --force "$job_path/work" 2>/dev/null || {
          rm -rf "$job_path/work"
          git -C "$repo" worktree prune 2>/dev/null || true
        }
      fi
      rm -rf "$job_path"
      submit_results+=("$(json_out '{ticket: $t, id: null, error: $err}' --arg t "$rel_ticket" --arg err "$err_msg")")
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
  local runner model timeout
  runner="$(jq -r .runner "$job_dir/meta.json")"
  model="$(jq -r .model "$job_dir/meta.json")"
  timeout="$(jq -r .timeout "$job_dir/meta.json")"

  local prompt_file="$job_dir/prompt.txt"
  cat "$SUBCON_PROMPT_PREAMBLE" "$job_dir/ticket.md" > "$prompt_file"

  export SUBCON_PROMPT_FILE="$prompt_file"
  export SUBCON_MODEL="$model"
  export SUBCON_TIMEOUT="$timeout"
  export SUBCON_SCHEMA="$SUBCON_SCHEMA"
  export SUBCON_SETTINGS="$SUBCON_SETTINGS"

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

  local id repo ticket base
  id="$(jq -r .id "$job_dir/meta.json")"
  repo="$(jq -r .repo "$job_dir/meta.json")"
  ticket="$(jq -r .ticket "$job_dir/meta.json")"
  base="$(jq -r .base "$job_dir/meta.json")"

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

  # 2. Write result.json
  jq -cn \
    --arg id "$id" \
    --arg repo "$repo" \
    --arg ticket "$ticket" \
    --arg state "$final_state" \
    --arg status "$status" \
    --arg error "$error" \
    --arg has_patch "$has_patch" \
    --arg patch "$job_dir/patch.diff" \
    --arg diffstat "$diffstat" \
    --argjson checks "$checks" \
    --argjson report "$report" \
    '{
      id: $id,
      repo: $repo,
      ticket: $ticket,
      state: $state,
      status: (if $status == "" then null else $status end),
      checks: (if $has_patch == "1" then $checks else null end),
      report: $report,
      patch: (if $has_patch == "1" then $patch else null end),
      diffstat: (if $has_patch == "1" then $diffstat else null end),
      error: (if $error == "" then null else $error end)
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
