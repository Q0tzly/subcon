#!/bin/bash
set -euo pipefail

if ! command -v agy >/dev/null 2>&1 && [[ -n "${HOME:-}" && -x "$HOME/.local/bin/agy" ]]; then
  export PATH="$HOME/.local/bin${PATH:+:$PATH}"
fi

job_dir="${SUBCON_JOB_DIR:?SUBCON_JOB_DIR required}"

# Set for a resumed job: continue that agy conversation instead of starting a new one.
resume_flags=()
[[ -z "${SUBCON_CONVERSATION:-}" ]] || resume_flags=(--conversation "$SUBCON_CONVERSATION")

# stream-json emits the conversation_id in its first event, so a run that is killed
# before agy writes its final result can still be resumed.
stream="$job_dir/agy.stream"
rc=0
agy -p "$(cat "$SUBCON_PROMPT_FILE")" \
  ${resume_flags[@]+"${resume_flags[@]}"} \
  --model "$SUBCON_JOB_MODEL" \
  --mode accept-edits \
  --sandbox \
  --settings "$SUBCON_SETTINGS" \
  --output-format stream-json \
  --json-schema "$SUBCON_SCHEMA" \
  --disable-slash-commands \
  --print-timeout "$SUBCON_TIMEOUT" > "$stream" || rc=$?

# agy.json keeps the shape of `--output-format json`: the final result event's payload.
{ jq -c 'select(.event == "result") | .result' "$stream" 2>/dev/null || true; } | tail -n 1 > "$job_dir/agy.json"
if [[ ! -s "$job_dir/agy.json" ]]; then
  conversation="$({ jq -r 'select(.event == "init") | .conversation_id' "$stream" 2>/dev/null || true; } | head -n 1)"
  if [[ -n "$conversation" ]]; then
    jq -cn --arg c "$conversation" '{status: "ERROR", conversation_id: $c, error: "agy exited without a result"}' > "$job_dir/agy.json"
  else
    rm -f "$job_dir/agy.json"
  fi
fi
exit "$rc"
