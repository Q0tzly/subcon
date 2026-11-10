#!/bin/bash
# Link subcon into PATH. Agents read the rules with `subcon guide`.
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
