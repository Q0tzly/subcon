# Shared helpers, sourced by bin/subcon. Expects SUBCON_ROOT to be set.

SUBCON_DEFAULT_MODEL=gemini-3.8-flash-medium
SUBCON_DEFAULT_TIMEOUT=30m
SUBCON_COAUTHOR_EMAIL="${SUBCON_COAUTHOR_EMAIL:-noreply@google.com}"
SUBCON_SCHEMA="$SUBCON_ROOT/schema/result.schema.json"
SUBCON_PROMPT_PREAMBLE="$SUBCON_ROOT/lib/prompt.md"
SUBCON_RESUME_PROMPT="$SUBCON_ROOT/lib/resume-prompt.md"

# Headless agy auto-denies anything not allowed, which aborts the whole run,
# so allow every command and deny the ones that change git state or reach out.
# Rules match whole words as a prefix: command(git commit) covers "git commit -m x".
# agy has no CLI setting to forbid BypassSandbox, and command(*) also approves
# unsandboxed runs; the deny list applies to those too.
SUBCON_SETTINGS='{"permissions":{
  "allow":["command(*)"],
  "deny":[
    "command(git commit)","command(git add)","command(git reset)","command(git checkout)",
    "command(git switch)","command(git restore)","command(git stash)","command(git rebase)",
    "command(git merge)","command(git push)","command(git clean)","command(git branch)",
    "command(git tag)","command(git rm)","command(git mv)","command(gh)","command(sudo)",
    "command(rm -rf)","command(rm -fr)"
  ]}}'

die() { echo "subcon: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

# json_out <jq-filter> [jq args...]: print one compact JSON value built with `jq -n`.
#   json_out '{path: $p}' --arg p "$path"
json_out() { jq -cn "$@"; }

# atomic_write <path>: write stdin to <path> via a temp file and rename,
# so readers never see a half-written file.
atomic_write() {
  local tmp
  tmp="$(mktemp "$1.XXXXXX")"
  cat > "$tmp"
  mv -f "$tmp" "$1"
}

state_root() { echo "${SUBCON_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/subcon}"; }
jobs_dir() { echo "$(state_root)/jobs"; }
job_dir() { echo "$(jobs_dir)/$1"; }

repo_top() { git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"; }

default_model() { echo "${SUBCON_MODEL:-$SUBCON_DEFAULT_MODEL}"; }

# "Gemini 3.8 Flash (Medium)" -> "Gemini 3.8 Flash"
model_name() {
  agy models 2>/dev/null | awk -F'\t' -v id="$1" '$1 == id { sub(/ \([^)]*\)$/, "", $2); print $2 }'
}

cmd_trailer() {
  local model
  model="$(default_model)"
  if [[ "${1:-}" == "--model" ]]; then
    model="${2:?--model needs a value}"
  fi
  local name
  name="$(model_name "$model")"
  [[ -n "$name" ]] || die "unknown model: $model (see: agy models)"
  echo "Co-Authored-By: $name <$SUBCON_COAUTHOR_EMAIL>"
}
