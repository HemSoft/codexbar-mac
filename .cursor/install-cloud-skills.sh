#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_dir="$repo_root/.agents/skills/identify-issues"

if [[ ! -f "$source_dir/SKILL.md" ]]; then
  printf 'Missing identify-issues skill: %s\n' "$source_dir/SKILL.md" >&2
  exit 1
fi

install_skill() {
  local destination="$1"

  mkdir -p -- "$(dirname -- "$destination")"
  rm -rf -- "$destination"
  cp -R -- "$source_dir" "$destination"
  test -f "$destination/SKILL.md"
}

# The plural path is Cursor's supported user-level skill directory. Keep the
# singular compatibility copy while the existing Automation prompt names it.
install_skill "$HOME/.agents/skills/identify-issues"
install_skill "$HOME/.agents/skill/identify-issues"

printf 'Installed identify-issues skill for Cursor Cloud.\n'
