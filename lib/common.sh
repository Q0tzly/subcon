# Shared helpers, sourced by bin/subcon. Expects SUBCON_ROOT to be set.

SUBCON_DEFAULT_TIMEOUT=30m
SUBCON_COAUTHOR_EMAIL="${SUBCON_COAUTHOR_EMAIL:-noreply@google.com}"
SUBCON_SCHEMA="$SUBCON_ROOT/schema/result.schema.json"
SUBCON_PROMPT_PREAMBLE="$SUBCON_ROOT/lib/prompt.md"
SUBCON_RESUME_PROMPT="$SUBCON_ROOT/lib/resume-prompt.md"

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

# driver_path <name>: the executable drivers/<name>, or return 1.
# Names come from the command line, so anything that is not a plain word is refused.
driver_path() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  local bin="$SUBCON_ROOT/drivers/$name"
  [[ -x "$bin" ]] || return 1
  echo "$bin"
}

require_driver() {
  local name="$1" bin
  bin="$(driver_path "$name")" || die "unknown driver: $name"
  "$bin" preflight || die "driver preflight failed: $name"
}

# default_model <driver>: SUBCON_MODEL if set, else the driver's default.
default_model() {
  if [[ -n "${SUBCON_MODEL:-}" ]]; then
    echo "$SUBCON_MODEL"
    return 0
  fi
  "$(driver_path "$1")" default-model
}

container_engine() {
  local bin
  if [[ -n "${SUBCON_CONTAINER_ENGINE:-}" ]]; then
    if bin="$(command -v "$SUBCON_CONTAINER_ENGINE" 2>/dev/null)" && [[ -n "$bin" ]]; then
      echo "$bin"
      return 0
    fi
    return 1
  fi
  if bin="$(command -v docker 2>/dev/null)" && [[ -n "$bin" ]]; then
    echo "$bin"
    return 0
  fi
  if bin="$(command -v podman 2>/dev/null)" && [[ -n "$bin" ]]; then
    echo "$bin"
    return 0
  fi
  return 1
}

require_container() {
  local engine
  engine="$(container_engine)" || die "container engine not found: install docker or podman"
  local image="${SUBCON_CONTAINER_IMAGE:-subcon-runner:latest}"
  "$engine" image inspect "$image" >/dev/null 2>&1 || die "container image not found: $image (build it from container/Containerfile)"
}

require_ci() {
  local repo="$1"
  command -v gh >/dev/null 2>&1 || die "ci runner requires gh: install the GitHub CLI"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated: run gh auth login"
  [[ -f "$repo/.github/workflows/subcon-job.yml" ]] || die "workflow not found: .github/workflows/subcon-job.yml (add the subcon-job workflow to this repository)"
}

agy_auth_mode() {
  local settings="${HOME:-}/.gemini/antigravity-cli/settings.json"
  local provider=""
  if [[ -n "${HOME:-}" && -f "$settings" ]]; then
    provider="$(jq -r '.modelProvider // empty' "$settings" 2>/dev/null)" || provider=""
  fi
  if [[ "$provider" == "gemini" ]]; then
    echo "api-key"
  else
    echo "consumer"
  fi
  return 0
}

warn_consumer_auth() {
  if [[ "$(agy_auth_mode)" == "consumer" && -z "${SUBCON_NO_AUTH_WARNING:-}" ]]; then
    echo 'subcon: warning: agy is using a consumer Google login. Driving agy from a third-party agent on a consumer plan (AI Pro etc.) violates Antigravity'\''s terms and risks account suspension. Supported options: switch agy to an API key (set "modelProvider": "gemini" in ~/.gemini/antigravity-cli/settings.json and export GEMINI_API_KEY), or run subcon from your own scripts/CI. Silence with SUBCON_NO_AUTH_WARNING=1.' >&2
  fi
  return 0
}

# model_name <model> <driver>: "Gemini 3.8 Flash (Medium)" -> "Gemini 3.8 Flash"
model_name() {
  local bin
  bin="$(driver_path "$2")" || return 1
  "$bin" models 2>/dev/null | awk -F'\t' -v id="$1" '$1 == id { sub(/ \([^)]*\)$/, "", $2); print $2 }'
}

cmd_trailer() {
  local driver="${SUBCON_DRIVER:-agy}" model=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
      *)
        die "unknown option: $1"
        ;;
    esac
  done
  require_driver "$driver"
  [[ -n "$model" ]] || model="$(default_model "$driver")"
  local name
  name="$(model_name "$model" "$driver")"
  [[ -n "$name" ]] || die "unknown model: $model (see: $driver models)"
  echo "Co-Authored-By: $name <$SUBCON_COAUTHOR_EMAIL>"
}
