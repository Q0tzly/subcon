#!/bin/bash
# Link subcon into PATH, and its skill into Muse when Muse is present.
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

# The VM-hosted Muse reads skills from ~/workspace/custom-skills and ships
# no `muse` command, so detect it by its runtime or its skills directory.
# A muse CLI install, when one exists, uses the XDG config root instead.
# Linking keeps the skill in sync with the repo.
if command -v hatch >/dev/null || [ -d "$HOME/workspace/custom-skills" ]; then
  link skills/subcon "$HOME/workspace/custom-skills/subcon"
elif command -v muse >/dev/null; then
  link skills/subcon "${XDG_CONFIG_HOME:-$HOME/.config}/muse/skills/subcon"
fi
