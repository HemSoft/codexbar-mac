#!/usr/bin/env bash
set -euo pipefail

destination="${1:?usage: install-swiftlint.sh <destination-directory>}"
script_directory="$(cd "$(dirname "$0")" && pwd)"
policy="$script_directory/policy.json"
IFS=$'\t' read -r version archive_url archive_sha256 < <(
  python3 - "$policy" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    tools = json.load(stream)['tools']
print('\t'.join((tools['swiftlint'], tools['swiftlint_archive'], tools['swiftlint_archive_sha256'])))
PY
)
archive="$destination/portable_swiftlint.zip"
executable="$destination/swiftlint"

mkdir -p "$destination"

if [[ ! -x "$executable" ]] || [[ "$("$executable" version 2>/dev/null || true)" != "$version" ]]; then
  curl --fail --location --silent --show-error "$archive_url" --output "$archive"
  printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 --check --status
  unzip -oq "$archive" swiftlint -d "$destination"
  chmod +x "$executable"
fi

actual_version="$("$executable" version)"
if [[ "$actual_version" != "$version" ]]; then
  echo "Expected SwiftLint $version, found $actual_version" >&2
  exit 1
fi

printf '%s\n' "$executable"
