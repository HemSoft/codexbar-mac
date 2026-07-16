#!/usr/bin/env bash
# Cut CHANGELOG.md Unreleased notes into a dated version section and emit release notes.
#
# Usage:
#   ./scripts/cut-changelog.sh [--write] [--notes-out PATH] <version>
#
# Without --write, prints the release notes for <version> derived from the current
# Unreleased section (or the matching dated section if already cut) and exits 0.
# With --write, rewrites CHANGELOG.md so Unreleased becomes "## <version> - <today>"
# and a fresh empty Unreleased section is inserted above it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"
WRITE=0
NOTES_OUT=""

usage() {
  echo "Usage: $0 [--write] [--notes-out PATH] <version>" >&2
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --write)
      WRITE=1
      shift
      ;;
    --notes-out)
      [[ $# -ge 2 ]] || usage
      NOTES_OUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 1 ]] || usage
VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || {
  echo "Version must look like 1.0 or 1.0.0, got: $VERSION" >&2
  exit 1
}

[[ -f "$CHANGELOG" ]] || {
  echo "Missing changelog: $CHANGELOG" >&2
  exit 1
}

python3 - "$CHANGELOG" "$VERSION" "$WRITE" "$NOTES_OUT" <<'PY'
import pathlib
import re
import sys
from datetime import date

changelog_path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
write = sys.argv[3] == "1"
notes_out = sys.argv[4]

text = changelog_path.read_text(encoding="utf-8")
heading_re = re.compile(r"^## (.+)$", re.MULTILINE)
matches = list(heading_re.finditer(text))
if not matches:
    raise SystemExit("CHANGELOG.md has no ## headings")

def section_body(start_idx: int) -> str:
    start = matches[start_idx].end()
    end = matches[start_idx + 1].start() if start_idx + 1 < len(matches) else len(text)
    return text[start:end].strip("\n")

unreleased_idx = next((i for i, m in enumerate(matches) if m.group(1).strip() == "Unreleased"), None)
version_prefix = f"{version} -"
version_idx = next(
    (
        i
        for i, m in enumerate(matches)
        if m.group(1).strip() == version or m.group(1).strip().startswith(version_prefix)
    ),
    None,
)

if unreleased_idx is None and version_idx is None:
    raise SystemExit(f"No Unreleased section and no section for {version}")

if version_idx is not None:
    notes = section_body(version_idx).strip()
    if not notes:
        raise SystemExit(f"Version section {matches[version_idx].group(1)!r} is empty")
else:
    notes = section_body(unreleased_idx).strip()
    if not notes:
        raise SystemExit("Unreleased section is empty; nothing to release")

    if write:
        today = date.today().isoformat()
        empty_unreleased = "## Unreleased\n\n### Added\n\n### Fixed\n\n### Developer Experience\n"
        cut_heading = f"## {version} - {today}"
        before = text[: matches[unreleased_idx].start()]
        after_start = (
            matches[unreleased_idx + 1].start()
            if unreleased_idx + 1 < len(matches)
            else len(text)
        )
        after = text[after_start:]
        rewritten = (
            before
            + empty_unreleased
            + "\n"
            + cut_heading
            + "\n\n"
            + notes
            + "\n\n"
            + after.lstrip("\n")
        )
        changelog_path.write_text(rewritten, encoding="utf-8")

release_notes = f"# CodexBar for Mac {version}\n\n{notes}\n"
if notes_out:
    pathlib.Path(notes_out).write_text(release_notes, encoding="utf-8")
else:
    sys.stdout.write(release_notes)
PY
