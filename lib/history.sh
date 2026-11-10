# Append-only usage history, kept after discard (ticket 10).

history_file() { echo "$(state_root)/history.jsonl"; }

_history_append() {
  local line="$1"
  local hfile
  hfile="$(history_file)"
  local hdir
  hdir="$(state_root)"
  [[ -d "$hdir" ]] || mkdir -p "$hdir" || return 1

  local lock="${hfile}.lock"
  local locked=0
  local i
  for ((i = 0; i < 50; i++)); do
    if mkdir "$lock" 2>/dev/null; then
      locked=1
      break
    fi
    sleep 0.1
  done

  if [[ $locked -ne 1 ]]; then
    echo "subcon: failed to acquire lock for $hfile" >&2
    return 1
  fi

  printf '%s\n' "$line" >> "$hfile"
  local rc=$?
  rmdir "$lock" 2>/dev/null || true
  return $rc
}

history_append_job() {
  local job_dir="${1:?job directory required}"
  [[ "$job_dir" = /* ]] || job_dir="$(pwd)/$job_dir"

  local meta_file="$job_dir/meta.json"
  local result_file="$job_dir/result.json"
  local agy_file="$job_dir/agy.json"

  [[ -f "$meta_file" ]] || { echo "subcon: meta.json missing in $job_dir" >&2; return 1; }
  [[ -f "$result_file" ]] || { echo "subcon: result.json missing in $job_dir" >&2; return 1; }

  local agy_json="null"
  if [[ -f "$agy_file" ]] && jq -e . "$agy_file" >/dev/null 2>&1; then
    agy_json="$(cat "$agy_file")"
  fi

  local finished_at
  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local line
  line="$(jq -cn \
    --arg finished_at "$finished_at" \
    --argjson meta "$(< "$meta_file")" \
    --argjson result "$(< "$result_file")" \
    --argjson agy "$agy_json" \
    '{
      type: "job",
      id: $meta.id,
      repo: $meta.repo,
      ticket: $meta.ticket,
      model: $meta.model,
      runner: $meta.runner,
      created_at: $meta.created_at,
      finished_at: $finished_at,
      duration_s: (
        if ($agy | type == "object") and ($agy | has("duration_seconds")) and $agy.duration_seconds != null
        then $agy.duration_seconds
        else null
        end
      ),
      state: $result.state,
      status: ($result.status // null),
      checks_ok: (if $result.checks == null then null else $result.checks.ok end),
      files_changed: (if $result.checks == null then null else ($result.checks.files_changed | length) end),
      insertions: (
        if $result.diffstat == null then null
        elif $result.diffstat == "" then 0
        else ([($result.diffstat | match("([0-9]+) insertion") | .captures[0].string | tonumber)][0] // 0)
        end
      ),
      deletions: (
        if $result.diffstat == null then null
        elif $result.diffstat == "" then 0
        else ([($result.diffstat | match("([0-9]+) deletion") | .captures[0].string | tonumber)][0] // 0)
        end
      ),
      tokens: (
        if ($agy | type == "object") and ($agy.usage | type == "object") and $agy.usage != null then
          {
            input: $agy.usage.input_tokens,
            output: $agy.usage.output_tokens,
            total: $agy.usage.total_tokens
          }
        else null
        end
      ),
      resume_of: (
        if ($meta | has("resume_of")) and $meta.resume_of != null
        then $meta.resume_of
        else null
        end
      )
    }')" || return 1

  _history_append "$line"
}

history_append_event() {
  local id="${1:?job id required}"
  local event="${2:?event required}"
  local at
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  local line
  line="$(jq -cn \
    --arg id "$id" \
    --arg event "$event" \
    --arg at "$at" \
    '{type: "event", id: $id, event: $event, at: $at}')" || return 1

  _history_append "$line"
}
