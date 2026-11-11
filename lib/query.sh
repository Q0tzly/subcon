# Waiting for and showing job results (ticket 05).

job_result() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "subcon: job id required" >&2; return 1; }

  local dir
  dir="$(job_dir "$id")"
  if [[ ! -d "$dir" ]]; then
    echo "subcon: unknown job id: $id" >&2
    return 1
  fi

  local state
  state="$(cat "$dir/state" 2>/dev/null || echo "")"

  if [[ "$state" == "queued" || "$state" == "running" ]]; then
    local pid=""
    [[ -f "$dir/pid" ]] && pid="$(cat "$dir/pid" 2>/dev/null || echo "")"
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
      state="$(cat "$dir/state" 2>/dev/null || echo "")"
      if [[ "$state" == "queued" || "$state" == "running" ]]; then
        job_finalize "$dir" died
        state="$(cat "$dir/state" 2>/dev/null || echo "")"
      fi
    fi
  fi

  if [[ "$state" == "queued" || "$state" == "running" ]]; then
    local repo="" ticket=""
    if [[ -f "$dir/meta.json" ]]; then
      repo="$(jq -r .repo "$dir/meta.json" 2>/dev/null || echo "")"
      ticket="$(jq -r .ticket "$dir/meta.json" 2>/dev/null || echo "")"
    fi
    jq -cn \
      --arg id "$id" \
      --arg repo "$repo" \
      --arg ticket "$ticket" \
      --arg state "$state" \
      '{
        v: 1,
        id: $id,
        repo: (if $repo == "" then null else $repo end),
        ticket: (if $ticket == "" then null else $ticket end),
        state: $state,
        status: null,
        checks: null,
        report: null,
        patch: null,
        diffstat: null,
        error: null,
        agy_error: null,
        conversation: null
      }'
  else
    if [[ -f "$dir/result.json" ]]; then
      cat "$dir/result.json"
    else
      job_finalize "$dir" died
      cat "$dir/result.json"
    fi
  fi
}

exit_code_for() {
  local json="${1:-}"
  if [[ $# -eq 0 ]]; then
    json="$(cat)"
  fi
  [[ -n "$json" ]] || return 0

  local code
  code="$(jq -cn --argjson d "$json" '
    ($d | if type == "array" then . else [.] end)
    | map(
        if .state == "failed" then 4
        elif (.checks != null and .checks.ok == false) then 3
        elif (.status == "partial" or .status == "blocked" or (.state == "finished" and .status == null)) then 2
        else 0
        end
      )
    | max // 0
  ' 2>/dev/null || echo 1)"
  return "$code"
}

cmd_show() {
  local id="${1:-}"
  [[ -n "$id" ]] || { echo "subcon: show: job id required" >&2; return 1; }

  local res rc=0
  res="$(job_result "$id")" || rc=$?
  if [[ $rc -ne 0 ]]; then
    return "$rc"
  fi

  printf '%s\n' "$res"
  exit_code_for "$res"
}

cmd_wait() {
  local timeout=0
  local ids=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires a value"
        timeout="$2"
        shift 2
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        ids+=("$1")
        shift
        ;;
    esac
  done

  [[ ${#ids[@]} -gt 0 ]] || die "at least one job id required"

  local id
  for id in "${ids[@]}"; do
    local d
    d="$(job_dir "$id")"
    if [[ ! -d "$d" ]]; then
      echo "subcon: unknown job id: $id" >&2
      return 1
    fi
  done

  local timed_out=0
  local start_time=$SECONDS
  local results_json=""

  while true; do
    local all_done=1
    local cur_results=()
    for id in "${ids[@]}"; do
      local res rc=0
      res="$(job_result "$id")" || rc=$?
      if [[ $rc -ne 0 ]]; then
        return "$rc"
      fi
      cur_results+=("$res")
      local st
      st="$(jq -r .state <<<"$res")"
      if [[ "$st" == "queued" || "$st" == "running" ]]; then
        all_done=0
      fi
    done

    if [[ $all_done -eq 1 ]]; then
      results_json="$(printf '%s\n' "${cur_results[@]}" | jq -sc .)"
      break
    fi

    if (( timeout > 0 && SECONDS - start_time >= timeout )); then
      timed_out=1
      results_json="$(printf '%s\n' "${cur_results[@]}" | jq -sc .)"
      break
    fi

    sleep 0.5
  done

  printf '%s\n' "$results_json"

  if [[ $timed_out -eq 1 ]]; then
    return 5
  fi

  exit_code_for "$results_json"
}

cmd_run() {
  local tickets=()
  local pass_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --runner|--model|--driver|--timeout)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        pass_args+=("$1" "$2")
        shift 2
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        tickets+=("$1")
        pass_args+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#tickets[@]} -eq 0 ]]; then
    die "run takes one ticket"
  elif [[ ${#tickets[@]} -gt 1 ]]; then
    die "run takes only one ticket"
  fi

  local submit_out submit_rc=0
  submit_out="$(cmd_submit "${pass_args[@]}")" || submit_rc=$?
  if [[ $submit_rc -ne 0 ]]; then
    if [[ -n "$submit_out" ]]; then
      if jq -e 'type == "array"' <<<"$submit_out" >/dev/null 2>&1; then
        jq -c '.[0]' <<<"$submit_out"
      else
        printf '%s\n' "$submit_out"
      fi
    fi
    return "$submit_rc"
  fi

  local id
  id="$(jq -r '.[0].id // empty' <<<"$submit_out")"
  if [[ -z "$id" ]]; then
    [[ -n "$submit_out" ]] && printf '%s\n' "$submit_out"
    return 4
  fi

  local wait_out wait_rc=0
  wait_out="$(cmd_wait "$id")" || wait_rc=$?

  jq -c '.[0]' <<<"$wait_out"
  return "$wait_rc"
}
