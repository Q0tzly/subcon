# Ticket parsing, validation and templates (ticket 03).

cmd_new() {
  local arg="${1:-}"
  if [[ $# -ne 1 || ! "$arg" =~ ^[A-Za-z0-9_-]+/[A-Za-z0-9_-]+$ ]]; then
    die "invalid ticket argument: $arg"
  fi
  local top
  top="$(repo_top)"
  local rel="docs/design/${arg}.md"
  local target="$top/$rel"
  if [[ -e "$target" ]]; then
    die "ticket already exists: $rel"
  fi
  local tmpl="$SUBCON_ROOT/templates/ticket.md"
  [[ -f "$tmpl" ]] || die "template not found: $tmpl"
  local title="${arg#*/}"
  mkdir -p "$(dirname "$target")"
  sed "1s/^# <title>/# ${title}/" "$tmpl" > "$target"
  json_out '{path: $p}' --arg p "$rel"
}

cmd_guide() {
  local doc="$SUBCON_ROOT/docs/delegation.md"
  [[ -f "$doc" ]] || die "guide not found: $doc"
  cat "$doc"
}

ticket_files() {
  awk '/^## /{ in_files = ($0 ~ /^## Files[[:space:]]*$/); next }
       in_files && /^[[:space:]]*[-*][[:space:]]+/ {
         sub(/^[[:space:]]*[-*][[:space:]]+/, ""); gsub(/`/, ""); sub(/[[:space:]].*$/, ""); print
       }' "$1"
}

ticket_validate() {
  local path="${1:-}"
  [[ -n "$path" ]] || { echo "subcon: invalid ticket: path required" >&2; return 1; }
  [[ -f "$path" ]] || { echo "subcon: invalid ticket: file not found: $path" >&2; return 1; }
  git cat-file -e "HEAD:$path" 2>/dev/null || { echo "subcon: invalid ticket: not committed in HEAD: $path" >&2; return 1; }
  git diff --quiet HEAD -- "$path" 2>/dev/null || { echo "subcon: invalid ticket: uncommitted changes: $path" >&2; return 1; }

  local count=0 f
  while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -z "$f" ]] && { echo "subcon: invalid ticket: empty path in ## Files: $path" >&2; return 1; }
    count=$((count + 1))
    if [[ "$f" == /* ]]; then
      { echo "subcon: invalid ticket: path starts with /: $f" >&2; return 1; }
    fi
    if [[ "$f" =~ (^|/)\.\.?(/|$) ]]; then
      { echo "subcon: invalid ticket: path element cannot be . or ..: $f" >&2; return 1; }
    fi
    if [[ "$f" == *[\*\?\[]* ]]; then
      { echo "subcon: invalid ticket: path contains glob characters (*, ?, [): $f" >&2; return 1; }
    fi
  done < <(ticket_files "$path")

  if [[ $count -eq 0 ]]; then
    { echo "subcon: invalid ticket: ## Files is empty: $path" >&2; return 1; }
  fi
}
