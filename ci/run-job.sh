#!/bin/bash
set -uo pipefail

if [[ -z "${SUBCON_CI_JOB:-}" || -z "${SUBCON_CI_TICKET:-}" || -z "${SUBCON_CI_BASE:-}" || -z "${SUBCON_CI_MODEL:-}" || -z "${SUBCON_CI_TIMEOUT:-}" ]]; then
  echo "ci/run-job.sh: missing required environment variable" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_REPO="${GITHUB_WORKSPACE:-$SELF_ROOT}"

export SUBCON_ROOT="$SELF_ROOT"
if ! source "$SELF_ROOT/lib/common.sh"; then
  echo "ci/run-job.sh: failed to source lib/common.sh" >&2
  exit 1
fi

runner_temp="${RUNNER_TEMP:-/tmp}"
runner_temp="${runner_temp%/}"
WORK_BASE="${runner_temp}/subcon-${SUBCON_CI_JOB}"
JOB_DIR="$WORK_BASE/job"
ARTIFACT_DIR="$WORK_BASE/artifact"

rm -rf "$WORK_BASE"
mkdir -p "$JOB_DIR" "$ARTIFACT_DIR" || exit 1

ticket_path="$TARGET_REPO/$SUBCON_CI_TICKET"
if [[ ! -f "$ticket_path" ]]; then
  echo "ci/run-job.sh: ticket not found: $ticket_path" >&2
  exit 1
fi

# 1. job/ticket.md に対象リポジトリの票をコピーし、prompt.txt = 前文 + ticket.md を作る
cp "$ticket_path" "$JOB_DIR/ticket.md" || exit 1
cat "$SUBCON_PROMPT_PREAMBLE" "$JOB_DIR/ticket.md" > "$JOB_DIR/prompt.txt" || exit 1

# 2. job/work に対象リポジトリを clone し、SUBCON_CI_BASE を checkout する
git clone -q "$TARGET_REPO" "$JOB_DIR/work" || exit 1
git -C "$JOB_DIR/work" checkout -q "$SUBCON_CI_BASE" || exit 1

# 3. SUBCON_PROMPT_FILE / SUBCON_JOB_MODEL / SUBCON_TIMEOUT / SUBCON_SCHEMA を export し、SUBCON_CONVERSATION は外して、runners/local を job/ に対して実行する
export SUBCON_PROMPT_FILE="$JOB_DIR/prompt.txt"
export SUBCON_JOB_MODEL="$SUBCON_CI_MODEL"
export SUBCON_TIMEOUT="$SUBCON_CI_TIMEOUT"
export SUBCON_SCHEMA="$SUBCON_SCHEMA"
unset SUBCON_CONVERSATION

runner_rc=0
"$SELF_ROOT/runners/local" "$JOB_DIR" || runner_rc=$?

# 4. 成否によらず成果物をまとめる: artifact/work.tar.gz（work/ をトップに含む tar）、job/agy.json があれば artifact/agy.json、job/agy.stream があれば artifact/agy.stream
mkdir -p "$ARTIFACT_DIR"
if [[ -d "$JOB_DIR/work" ]]; then
  tar -czf "$ARTIFACT_DIR/work.tar.gz" -C "$JOB_DIR" work
fi

if [[ -f "$JOB_DIR/agy.json" ]]; then
  cp "$JOB_DIR/agy.json" "$ARTIFACT_DIR/agy.json"
fi

if [[ -f "$JOB_DIR/agy.stream" ]]; then
  cp "$JOB_DIR/agy.stream" "$ARTIFACT_DIR/agy.stream"
fi

# 5. 最後に artifact ディレクトリのパスを stdout に出す
echo "$ARTIFACT_DIR"

exit "$runner_rc"
