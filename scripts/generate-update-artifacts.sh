#!/usr/bin/env bash
# Generate and validate a signed Sparkle appcast plus a deterministic Homebrew cask.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=""
ARCHIVE=""
NOTES=""
DOWNLOAD_PREFIX=""
RELEASE_PAGE_URL=""
APPCAST_OUTPUT=""
CASK_OUTPUT=""
EXISTING_APPCAST=""
SPARKLE_ACCOUNT="${CODEXBAR_SPARKLE_ACCOUNT:-codexbar-mac}"
GENERATE_APPCAST="${CODEXBAR_GENERATE_APPCAST:-}"
USE_KEYCHAIN_WRAPPER="${CODEXBAR_USE_KEYCHAIN_WRAPPER:-1}"

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/generate-update-artifacts.sh [options]

Required:
  --version <version>
  --archive <notarized-zip>
  --notes <release-notes.md>
  --download-prefix <immutable-release-download-prefix>
  --release-page-url <GitHub-release-url>
  --appcast-output <path>
  --cask-output <path>

Optional:
  --existing-appcast <path>  Preserve prior entries while adding this release

CODEXBAR_GENERATE_APPCAST must point to Sparkle's generate_appcast executable.
Set CODEXBAR_USE_KEYCHAIN_WRAPPER=0 only for isolated tests with a fake tool.
EOF
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || usage
      VERSION="$2"
      shift 2
      ;;
    --archive)
      [[ $# -ge 2 ]] || usage
      ARCHIVE="$2"
      shift 2
      ;;
    --notes)
      [[ $# -ge 2 ]] || usage
      NOTES="$2"
      shift 2
      ;;
    --download-prefix)
      [[ $# -ge 2 ]] || usage
      DOWNLOAD_PREFIX="$2"
      shift 2
      ;;
    --release-page-url)
      [[ $# -ge 2 ]] || usage
      RELEASE_PAGE_URL="$2"
      shift 2
      ;;
    --appcast-output)
      [[ $# -ge 2 ]] || usage
      APPCAST_OUTPUT="$2"
      shift 2
      ;;
    --cask-output)
      [[ $# -ge 2 ]] || usage
      CASK_OUTPUT="$2"
      shift 2
      ;;
    --existing-appcast)
      [[ $# -ge 2 ]] || usage
      EXISTING_APPCAST="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

[[ -n "$VERSION" && -n "$ARCHIVE" && -n "$NOTES" && -n "$DOWNLOAD_PREFIX" ]] || usage
[[ -n "$RELEASE_PAGE_URL" && -n "$APPCAST_OUTPUT" && -n "$CASK_OUTPUT" ]] || usage
[[ -f "$ARCHIVE" ]] || {
  echo "Release archive is missing: $ARCHIVE" >&2
  exit 1
}
[[ -f "$NOTES" ]] || {
  echo "Release notes are missing: $NOTES" >&2
  exit 1
}
[[ -x "$GENERATE_APPCAST" ]] || {
  echo "Sparkle generate_appcast is missing or not executable. Set CODEXBAR_GENERATE_APPCAST." >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "Missing required command: python3" >&2
  exit 1
}
[[ "$DOWNLOAD_PREFIX" =~ ^https://github[.]com/HemSoft/codexbar-mac/releases/download/v[^/]+/$ ]] || {
  echo "Download prefix must be an immutable CodexBar GitHub Release tag URL ending in /." >&2
  exit 1
}
[[ "$DOWNLOAD_PREFIX" == "https://github.com/HemSoft/codexbar-mac/releases/download/v$VERSION/" ]] || {
  echo "Download prefix tag must match version $VERSION." >&2
  exit 1
}
[[ "$RELEASE_PAGE_URL" =~ ^https://github[.]com/HemSoft/codexbar-mac/releases/tag/v[^/]+$ ]] || {
  echo "Release page URL must be a CodexBar GitHub Release tag URL." >&2
  exit 1
}
[[ "$RELEASE_PAGE_URL" == "https://github.com/HemSoft/codexbar-mac/releases/tag/v$VERSION" ]] || {
  echo "Release page tag must match version $VERSION." >&2
  exit 1
}
if [[ -n "$EXISTING_APPCAST" && ! -f "$EXISTING_APPCAST" ]]; then
  echo "Existing appcast is missing: $EXISTING_APPCAST" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ARCHIVE_NAME="CodexBarMac-$VERSION.zip"
NOTES_NAME="CodexBarMac-$VERSION.md"
cp "$ARCHIVE" "$WORK_DIR/$ARCHIVE_NAME"
cp "$NOTES" "$WORK_DIR/$NOTES_NAME"
if [[ -n "$EXISTING_APPCAST" ]]; then
  cp "$EXISTING_APPCAST" "$WORK_DIR/appcast.xml"
fi

GENERATOR_ARGS=(
  --account "$SPARKLE_ACCOUNT"
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --release-notes-url-prefix "$DOWNLOAD_PREFIX"
  --full-release-notes-url "$RELEASE_PAGE_URL"
  --link "https://github.com/HemSoft/codexbar-mac"
  --maximum-deltas 0
  -o "$WORK_DIR/appcast.xml"
  "$WORK_DIR"
)

if [[ "$USE_KEYCHAIN_WRAPPER" == "1" ]]; then
  "$ROOT/scripts/with-codexbar-keychain.sh" "$GENERATE_APPCAST" "${GENERATOR_ARGS[@]}"
elif [[ "$USE_KEYCHAIN_WRAPPER" == "0" ]]; then
  "$GENERATE_APPCAST" "${GENERATOR_ARGS[@]}"
else
  echo "CODEXBAR_USE_KEYCHAIN_WRAPPER must be 0 or 1." >&2
  exit 1
fi

EXPECTED_ARCHIVE_URL="${DOWNLOAD_PREFIX}${ARCHIVE_NAME}"
EXPECTED_NOTES_URL="${DOWNLOAD_PREFIX}${NOTES_NAME}"
[[ -f "$WORK_DIR/appcast.xml" ]] || {
  echo "Sparkle did not produce appcast.xml." >&2
  exit 1
}
grep -Fq '<!-- sparkle-signatures:' "$WORK_DIR/appcast.xml" || {
  echo "Generated appcast is not signed as a feed." >&2
  exit 1
}
python3 - \
  "$WORK_DIR/appcast.xml" \
  "$WORK_DIR/$ARCHIVE_NAME" \
  "$WORK_DIR/$NOTES_NAME" \
  "$VERSION" \
  "$EXPECTED_ARCHIVE_URL" \
  "$EXPECTED_NOTES_URL" <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

appcast_path, archive_path, notes_path, version, archive_url, notes_url = sys.argv[1:]
sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle"
attr = lambda name: f"{{{sparkle}}}{name}"

try:
    root = ET.parse(appcast_path).getroot()
except ET.ParseError as error:
    raise SystemExit(f"Generated appcast is not valid XML: {error}")

matches = []
for item in root.findall(".//item"):
    enclosure = item.find("enclosure")
    if enclosure is None:
        continue
    if enclosure.get("url") == archive_url and enclosure.get(attr("version")) == version:
        matches.append((item, enclosure))

if len(matches) != 1:
    raise SystemExit(
        f"Generated appcast must contain exactly one signed item for version {version}; "
        f"found {len(matches)}"
    )

item, enclosure = matches[0]
if enclosure.get("length") != str(os.path.getsize(archive_path)):
    raise SystemExit("Generated appcast archive length does not match the published archive.")
if not enclosure.get(attr("edSignature")):
    raise SystemExit("Generated appcast item is missing its archive EdDSA signature.")

notes_link = item.find(f"{{{sparkle}}}releaseNotesLink")
if notes_link is None or (notes_link.text or "").strip() != notes_url:
    raise SystemExit("Generated appcast item is missing its matching release-notes URL.")
if notes_link.get(attr("length")) != str(os.path.getsize(notes_path)):
    raise SystemExit("Generated appcast release-notes length does not match the signed notes.")
if not notes_link.get(attr("edSignature")):
    raise SystemExit("Generated appcast item is missing its release-notes EdDSA signature.")
PY

mkdir -p "$(dirname "$APPCAST_OUTPUT")"
cp "$WORK_DIR/appcast.xml" "$APPCAST_OUTPUT"
cp "$WORK_DIR/$NOTES_NAME" "$NOTES"

SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
"$ROOT/scripts/generate-homebrew-cask.sh" \
  --version "$VERSION" \
  --url "$EXPECTED_ARCHIVE_URL" \
  --sha256 "$SHA256" \
  --output "$CASK_OUTPUT"

echo "Generated signed appcast: $APPCAST_OUTPUT"
