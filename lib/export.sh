# Metadata export as JSON Lines for control planes (ticket 49). Format: docs/spec/files.md.

cmd_export() {
  local all=0
  local since_val=""
  local since_set=0

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
      -*)
        die "unknown option: $1"
        ;;
      *)
        die "unexpected argument: $1"
        ;;
    esac
  done

  local since_cutoff="null"
  if [[ $since_set -eq 1 ]]; then
    if [[ "$since_val" =~ ^([0-9]+)([dh])$ ]]; then
      local num="${BASH_REMATCH[1]}"
      local unit="${BASH_REMATCH[2]}"
      local cutoff_seconds
      if [[ "$unit" == "d" ]]; then
        cutoff_seconds=$(( num * 86400 ))
      else
        cutoff_seconds=$(( num * 3600 ))
      fi
      since_cutoff=$(( $(date +%s) - cutoff_seconds ))
    else
      die "invalid --since: $since_val"
    fi
  fi

  local cur_repo=""
  if [[ $all -eq 0 ]]; then
    cur_repo="$(repo_top)" || return 1
  fi

  local all_json="false"
  if [[ $all -eq 1 ]]; then
    all_json="true"
  fi

  local exported_at
  exported_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  jq -cn \
    --arg exported_at "$exported_at" \
    --argjson all "$all_json" \
    --arg repo "$cur_repo" \
    '{
      type: "export",
      v: 1,
      exported_at: $exported_at,
      scope: (if $all then "all" else "repo" end),
      repo: (if $all then null else $repo end)
    }' || return 1

  local hfile
  hfile="$(history_file)"
  if [[ -f "$hfile" ]]; then
    jq -c \
      --argjson all "$all_json" \
      --arg repo "$cur_repo" \
      --argjson since "$since_cutoff" \
      '
      select(.type == "job" and
        ($all or .repo == $repo) and
        ($since == null or ((try (.created_at | fromdateiso8601) catch 0) >= $since))
      )
      ' "$hfile" || return 1
  fi
}
