#!/usr/bin/env bash
# Smoke-test cut-changelog.sh against a temporary CHANGELOG fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/repo/scripts"
cp "$ROOT/scripts/cut-changelog.sh" "$TMP/repo/scripts/"

cat >"$TMP/repo/CHANGELOG.md" <<'EOF'
# Changelog

## Unreleased

### Added

- Feature one.
- Feature two.

### Fixed

- Bug fix.

### Developer Experience

- Tooling note.

## 0.9 - 2026-01-01

### Added

- Older stuff.
EOF

cp "$TMP/repo/CHANGELOG.md" "$TMP/CHANGELOG.orig.md"

"$TMP/repo/scripts/cut-changelog.sh" --notes-out "$TMP/notes.md" 1.0 >/dev/null
grep -q 'Feature one' "$TMP/notes.md"
grep -q 'Bug fix' "$TMP/notes.md"
cmp -s "$TMP/repo/CHANGELOG.md" "$TMP/CHANGELOG.orig.md"

"$TMP/repo/scripts/cut-changelog.sh" --write --notes-out "$TMP/notes2.md" 1.0 >/dev/null
grep -q '^## Unreleased$' "$TMP/repo/CHANGELOG.md"
grep -Eq '^## 1\.0 - [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$TMP/repo/CHANGELOG.md"
grep -q 'Feature one' "$TMP/repo/CHANGELOG.md"
grep -q 'Older stuff' "$TMP/repo/CHANGELOG.md"

python3 - <<'PY' "$TMP/repo/CHANGELOG.md"
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text()
parts = re.split(r"^## ", text, flags=re.M)
unreleased = next(p for p in parts if p.startswith("Unreleased"))
body = unreleased.split("\n", 1)[1]
assert "Feature one" not in body, body
assert "### Added" in body
print("cut-changelog smoke OK")
PY

# Heading-only Unreleased (post-cut template) must not publish empty notes.
if "$TMP/repo/scripts/cut-changelog.sh" --notes-out "$TMP/notes3.md" 1.1 >/dev/null 2>"$TMP/err.txt"; then
  echo "expected heading-only Unreleased to fail" >&2
  exit 1
fi
grep -q 'nothing to release' "$TMP/err.txt"

echo "scripts/test-cut-changelog.sh passed"
