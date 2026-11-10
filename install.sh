#!/bin/bash
# Link subcon into PATH, and its skill into Muse when muse is installed.
# Agents read the rules with `subcon guide`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"

link() {
  local src="$ROOT/$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]] && return
  if [[ -e "$dst" || -L "$dst" ]]; then
    mv "$dst" "$dst.bak.$(date +%Y%m%d%H%M%S)"
    echo "==> Backed up existing $dst"
  fi
  ln -s "$src" "$dst"
  echo "==> Linked $dst"
}

link bin/subcon "$HOME/.local/bin/subcon"

# Muse picks up skills from its config root; linking keeps the skill in sync with the repo.
if command -v muse >/dev/null; then
  link skills/subcon "${XDG_CONFIG_HOME:-$HOME/.config}/muse/skills/subcon"
fi
