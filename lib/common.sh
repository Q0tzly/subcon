# Shared helpers, sourced by bin/subcon. Expects SUBCON_ROOT to be set.

SUBCON_DEFAULT_TIMEOUT=30m
SUBCON_COAUTHOR_EMAIL="${SUBCON_COAUTHOR_EMAIL:-noreply@google.com}"

# The co-author email follows the implementer model's vendor;
# SUBCON_COAUTHOR_EMAIL is the fallback for names not listed here.
coauthor_email() {
  case "$1" in
    Claude*) echo "noreply@anthropic.com" ;;
    Gemini*) echo "noreply@google.com" ;;
    *) echo "$SUBCON_COAUTHOR_EMAIL" ;;
  esac
}
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
    echo 'subcon: warning: agy is using a consumer Google login. Driving agy from a third-party agent on a consumer plan (AI Pro etc.) violates Antigravity'\''s terms and risks suspension of your Google account. Supported options: switch agy to an API key (set "modelProvider": "gemini" in ~/.gemini/antigravity-cli/settings.json and export GEMINI_API_KEY), or call agy directly from your own scripts/CI. Silence with SUBCON_NO_AUTH_WARNING=1.' >&2
  fi
  return 0
}

# model_name <model> <driver>: "Gemini 3.8 Flash (Medium)" -> "Gemini 3.8 Flash".
# A model the driver does not list (e.g. opencode's provider/model) is returned as its ID.
model_name() {
  local bin name
  bin="$(driver_path "$2")" || return 1
  name="$("$bin" models 2>/dev/null | awk -F'\t' -v id="$1" '$1 == id { sub(/ \([^)]*\)$/, "", $2); print $2 }')"
  echo "${name:-$1}"
}

# github_slug <repo>: print "owner/repo" when the origin remote of <repo> is a GitHub URL.
github_slug() {
  local url
  url="$(git -C "$1" remote get-url origin 2>/dev/null)" || return 1
  url="${url%/}"
  url="${url%.git}"
  [[ "$url" =~ ^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$ ]] || return 1
  echo "${BASH_REMATCH[2]}"
}

# issue_ref_json <ref> <repo>: print the issue reference as {"repo": "owner/repo", "number": N}.
# Accepts #N (repo taken from <repo>'s GitHub origin), owner/repo#N, or
# https://github.com/owner/repo/issues/N. Prints nothing and returns 1 when the reference is
# not one of these forms, has no usable number, or needs an origin that is missing.
issue_ref_json() {
  local ref="$1" repo="$2" slug number
  if [[ "$ref" =~ ^#([0-9]+)$ ]]; then
    slug="$(github_slug "$repo")" || return 1
    number="${BASH_REMATCH[1]}"
  elif [[ "$ref" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
    slug="${BASH_REMATCH[1]}"
    number="${BASH_REMATCH[2]}"
  elif [[ "$ref" =~ ^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/([0-9]+)$ ]]; then
    slug="${BASH_REMATCH[1]}"
    number="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || return 1
  jq -cn --arg repo "$slug" --argjson number "$number" '{repo: $repo, number: $number}'
}

# latest_job_meta: print the meta.json of this repository's newest job
# (ordered by created_at, then meta.json mtime, then job ID).
# Returns 1 outside a git repository or when no job of this repository exists.
latest_job_meta() {
  local top d meta id repo ca mt
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -d "$(jobs_dir)" ]] || return 1

  local items=()
  for d in "$(jobs_dir)"/*; do
    [[ -d "$d" ]] || continue
    meta="$d/meta.json"
    [[ -f "$meta" ]] || continue
    repo="" ca=""
    IFS=$'\t' read -r repo ca < <(jq -r '[.repo // "", .created_at // ""] | @tsv' "$meta" 2>/dev/null) || true
    [[ "$repo" == "$top" ]] || continue
    id="$(basename "$d")"
    mt="$(date -r "$meta" +%s 2>/dev/null || stat -f %m "$meta" 2>/dev/null || stat -c %Y "$meta" 2>/dev/null || echo 0)"
    items+=("$(printf '%s\t%s\t%s\t%s' "$ca" "$mt" "$id" "$meta")")
  done

  if [[ ${#items[@]} -eq 0 ]]; then
    return 1
  fi

  printf '%s\n' "${items[@]}" | LC_ALL=C sort -t$'\t' -k1,1r -k2,2rn -k3,3r | head -1 | cut -f4
}

cmd_trailer() {
  local driver="" model="" driver_set=0 job_meta="" from_job=0
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
        driver_set=1
        shift 2
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
  if [[ $driver_set -eq 0 && -n "${SUBCON_DRIVER:-}" ]]; then
    driver="$SUBCON_DRIVER"
    driver_set=1
  fi
  if [[ $driver_set -eq 0 ]]; then
    if job_meta="$(latest_job_meta)" && driver="$(jq -r '.driver // "agy"' "$job_meta" 2>/dev/null)"; then
      from_job=1
    else
      driver="agy"
    fi
  fi
  if [[ -z "$model" && $from_job -eq 1 ]]; then
    model="$(jq -r '.model // empty' "$job_meta" 2>/dev/null)" || model=""
  fi
  require_driver "$driver"
  [[ -n "$model" ]] || model="$(default_model "$driver")"
  local name
  name="$(model_name "$model" "$driver")"
  [[ -n "$name" ]] || die "unknown model: $model (see: $driver models)"
  echo "Co-Authored-By: $name <$(coauthor_email "$name")>"
}
