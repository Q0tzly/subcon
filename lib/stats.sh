# Usage statistics from history.jsonl (ticket 11).

cmd_stats() {
  local all=0
  local since_val=""
  local since_set=0
  local text=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)
        all=1
        shift
        ;;
      --since)
        [[ $# -ge 2 ]] || die "--since requires a value"
        since_val="$2"
        since_set=1
        shift 2
        ;;
      --text)
        text=1
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

  local cutoff_seconds="null"
  local since_arg="null"
  if [[ $since_set -eq 1 ]]; then
    if [[ "$since_val" =~ ^([0-9]+)([dh])$ ]]; then
      local num="${BASH_REMATCH[1]}"
      local unit="${BASH_REMATCH[2]}"
      if [[ "$unit" == "d" ]]; then
        cutoff_seconds=$(( num * 86400 ))
      else
        cutoff_seconds=$(( num * 3600 ))
      fi
      since_arg="\"$since_val\""
    else
      die "invalid --since: $since_val"
    fi
  fi

  local cur_repo=""
  if [[ $all -eq 0 ]]; then
    cur_repo="$(repo_top)" || return 1
  fi

  local hfile
  hfile="$(history_file)"
  local input_file="/dev/null"
  if [[ -f "$hfile" ]]; then
    input_file="$hfile"
  fi

  local all_json="false"
  if [[ $all -eq 1 ]]; then
    all_json="true"
  fi

  local stats_json
  stats_json="$(jq -s -c \
    --argjson all "$all_json" \
    --arg repo "$cur_repo" \
    --argjson since "$since_arg" \
    --argjson cutoff "$cutoff_seconds" \
    '
    (now | floor) as $now |
    (if $cutoff == null then null else ($now - $cutoff) end) as $since_cutoff |
    (reduce (.[] | select(.type == "event" and .event == "applied")) as $e ({}; .[$e.id] = true)) as $applied_ids |
    (reduce (.[] | select(.type == "job")) as $j ({}; .[$j.id] = $j) | [.[]]) as $all_jobs |
    ($all_jobs | map(select(
      ($all or .repo == $repo) and
      ($since_cutoff == null or ((try (.created_at | fromdateiso8601) catch 0) >= $since_cutoff))
    ))) as $jobs |
    ($jobs | length) as $n_jobs |
    ($jobs | map(select(.state == "finished" and .status == "done" and .checks_ok == true)) | length) as $success |
    ($jobs | map(select($applied_ids[.id] == true)) | length) as $applied |
    ($jobs | map(select(.duration_s != null) | .duration_s) | sort) as $durs |
    ($jobs | map(select(.tokens != null) | .tokens)) as $toks |
    {
      "scope": (if $all then "all" else "repo" end),
      "repo": (if $all then null else $repo end),
      "since": $since,
      "jobs": $n_jobs,
      "by_state": {
        "finished": ($jobs | map(select(.state == "finished")) | length),
        "failed": ($jobs | map(select(.state == "failed")) | length)
      },
      "by_status": {
        "done": ($jobs | map(select(.status == "done")) | length),
        "partial": ($jobs | map(select(.status == "partial")) | length),
        "blocked": ($jobs | map(select(.status == "blocked")) | length),
        "none": ($jobs | map(select(.status == null)) | length)
      },
      "success": $success,
      "success_rate": (if $n_jobs == 0 then null else (((($success / $n_jobs) * 100) | round) / 100) end),
      "applied": $applied,
      "apply_rate": (if $n_jobs == 0 then null else (((($applied / $n_jobs) * 100) | round) / 100) end),
      "duration_s": (
        if ($durs | length) == 0 then
          null
        else
          {
            "total": ($durs | add),
            "median": (
              if ($durs | length) % 2 == 1 then
                $durs[(($durs | length) - 1) / 2]
              else
                (($durs[(($durs | length) / 2) - 1] + $durs[($durs | length) / 2]) / 2)
              end
            )
          }
        end
      ),
      "tokens": {
        "input": ($toks | map(.input // 0) | add // 0),
        "output": ($toks | map(.output // 0) | add // 0),
        "total": ($toks | map(.total // 0) | add // 0)
      },
      "by_model": (
        if $n_jobs == 0 then
          {}
        else
          ($jobs | group_by(.model) | map({
            key: .[0].model,
            value: {
              "jobs": length,
              "success": (map(select(.state == "finished" and .status == "done" and .checks_ok == true)) | length),
              "applied": (map(select($applied_ids[.id] == true)) | length),
              "tokens_total": (map(select(.tokens != null) | .tokens.total // 0) | add // 0)
            }
          }) | from_entries)
        end
      )
    }
    ' "$input_file")" || return 1

  if [[ $text -eq 0 ]]; then
    printf '%s\n' "$stats_json"
    return 0
  fi

  jq -rn --argjson s "$stats_json" '
    def pct(val): if val == null then "-" else "\((val * 1000 | round) / 10)%" end;
    def rpad(w): tostring | . + " " * ([0, w - length] | max);
    def lpad(w): tostring | (" " * ([0, w - length] | max)) + .;
    $s |
    "Jobs:          \(.jobs) (finished: \(.by_state.finished), failed: \(.by_state.failed))",
    "Success:       \(.success) (\(pct(.success_rate)))",
    "Applied:       \(.applied) (\(pct(.apply_rate)))",
    "Status:        done: \(.by_status.done), partial: \(.by_status.partial), blocked: \(.by_status.blocked), none: \(.by_status.none)",
    "Duration:      \(if .duration_s == null then "-" else "total \(.duration_s.total)s, median \(.duration_s.median)s" end)",
    "Tokens:        input \(.tokens.input), output \(.tokens.output), total \(.tokens.total)",
    "",
    "Model breakdown:",
    (
      if (.by_model | length) == 0 then
        "  (no jobs)"
      else
        "  MODEL                       JOBS   SUCCESS   APPLIED    TOKENS",
        (.by_model | to_entries[] | "  \((.key | rpad(26))) \((.value.jobs | lpad(5))) \((.value.success | lpad(9))) \((.value.applied | lpad(9))) \((.value.tokens_total | lpad(9)))")
      end
    )
  '
}
