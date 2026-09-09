#!/usr/bin/env bash
set -euo pipefail

destination="${1:?usage: install-swiftlint.sh <destination-directory>}"
version="0.65.1"
archive_url="https://github.com/realm/SwiftLint/releases/download/${version}/portable_swiftlint.zip"
archive_sha256="c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0"
archive="$destination/portable_swiftlint.zip"
executable="$destination/swiftlint"

mkdir -p "$destination"

if [[ ! -x "$executable" ]] || [[ "$($executable version 2>/dev/null || true)" != "$version" ]]; then
  curl --fail --location --silent --show-error "$archive_url" --output "$archive"
  printf '%s  %s\n' "$archive_sha256" "$archive" | shasum -a 256 --check --status
  unzip -oq "$archive" swiftlint -d "$destination"
  chmod +x "$executable"
fi

actual_version="$($executable version)"
if [[ "$actual_version" != "$version" ]]; then
  echo "Expected SwiftLint $version, found $actual_version" >&2
  exit 1
fi

printf '%s\n' "$executable"
