#!/usr/bin/env bash
# Smoke-test Sparkle/Homebrew release artifact generation without credentials or publication.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ARCHIVE="$TMP/CodexBarMac-1.2.3.zip"
NOTES="$TMP/CodexBarMac-1.2.3.md"
APPCAST="$TMP/appcast.xml"
CASK="$TMP/codexbar-mac.rb"
FAKE_GENERATOR="$TMP/generate_appcast"
CALL_LOG="$TMP/gh-calls.txt"

printf 'not-a-real-zip-but-stable-for-script-tests\n' >"$ARCHIVE"
printf '# CodexBar 1.2.3\n\nRelease notes.\n' >"$NOTES"

cat >"$FAKE_GENERATOR" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PREFIX=""
NOTES_PREFIX=""
OUTPUT=""
WORK_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account|--full-release-notes-url|--link|--maximum-deltas)
      shift 2
      ;;
    --download-url-prefix)
      PREFIX="$2"
      shift 2
      ;;
    --release-notes-url-prefix)
      NOTES_PREFIX="$2"
      shift 2
      ;;
    -o)
      OUTPUT="$2"
      shift 2
      ;;
    *)
      WORK_DIR="$1"
      shift
      ;;
  esac
done

[[ -f "$WORK_DIR/CodexBarMac-1.2.3.zip" ]]
[[ -f "$WORK_DIR/CodexBarMac-1.2.3.md" ]]
ARCHIVE_LENGTH="$(wc -c <"$WORK_DIR/CodexBarMac-1.2.3.zip" | tr -d '[:space:]')"
NOTES_LENGTH="$(wc -c <"$WORK_DIR/CodexBarMac-1.2.3.md" | tr -d '[:space:]')"
if [[ "${FAKE_UNSIGNED_CURRENT_ITEM:-0}" == "1" ]]; then
  cat >"$OUTPUT" <<XML
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:releaseNotesLink sparkle:edSignature="old-notes-signature" sparkle:length="1">https://example.com/old.md</sparkle:releaseNotesLink>
      <enclosure url="https://example.com/old.zip" length="1" sparkle:version="1.0.0" sparkle:edSignature="old-archive-signature"/>
    </item>
    <item>
      <sparkle:releaseNotesLink sparkle:length="${NOTES_LENGTH}">${NOTES_PREFIX}CodexBarMac-1.2.3.md</sparkle:releaseNotesLink>
      <enclosure url="${PREFIX}CodexBarMac-1.2.3.zip" length="${ARCHIVE_LENGTH}" sparkle:version="1.2.3"/>
    </item>
  </channel>
</rss>
<!-- sparkle-signatures:
edSignature: feed-signature
length: 1
-->
XML
  exit 0
fi
cat >"$OUTPUT" <<XML
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:releaseNotesLink sparkle:edSignature="notes-signature" sparkle:length="${NOTES_LENGTH}">${NOTES_PREFIX}CodexBarMac-1.2.3.md</sparkle:releaseNotesLink>
      <enclosure url="${PREFIX}CodexBarMac-1.2.3.zip" length="${ARCHIVE_LENGTH}" sparkle:version="1.2.3" sparkle:edSignature="archive-signature"/>
    </item>
  </channel>
</rss>
<!-- sparkle-signatures:
edSignature: feed-signature
length: 1
-->
XML
EOF
chmod +x "$FAKE_GENERATOR"

CODEXBAR_GENERATE_APPCAST="$FAKE_GENERATOR" \
CODEXBAR_USE_KEYCHAIN_WRAPPER=0 \
  "$ROOT/scripts/generate-update-artifacts.sh" \
    --version 1.2.3 \
    --archive "$ARCHIVE" \
    --notes "$NOTES" \
    --download-prefix "https://github.com/HemSoft/codexbar-mac/releases/download/v1.2.3/" \
    --release-page-url "https://github.com/HemSoft/codexbar-mac/releases/tag/v1.2.3" \
    --appcast-output "$APPCAST" \
    --cask-output "$CASK"

grep -Fq 'releases/download/v1.2.3/CodexBarMac-1.2.3.zip' "$APPCAST"
grep -Fq '<!-- sparkle-signatures:' "$APPCAST"
grep -Fq 'version "1.2.3"' "$CASK"
grep -Fq 'auto_updates true' "$CASK"
grep -Fq 'app "CodexBarMac.app"' "$CASK"
grep -Fq 'depends_on macos: ">= :sonoma"' "$CASK"

EXPECTED_SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
grep -Fq "sha256 \"$EXPECTED_SHA\"" "$CASK"

SECOND_CASK="$TMP/codexbar-mac-second.rb"
"$ROOT/scripts/generate-homebrew-cask.sh" \
  --version 1.2.3 \
  --url "https://github.com/HemSoft/codexbar-mac/releases/download/v1.2.3/CodexBarMac-1.2.3.zip" \
  --sha256 "$EXPECTED_SHA" \
  --output "$SECOND_CASK"
cmp -s "$CASK" "$SECOND_CASK"

if "$ROOT/scripts/generate-homebrew-cask.sh" \
  --version 1.2.3 \
  --url "https://example.com/mutable.zip" \
  --sha256 invalid \
  --output "$TMP/invalid.rb" >/dev/null 2>&1
then
  echo "expected invalid cask inputs to fail" >&2
  exit 1
fi

if CODEXBAR_GENERATE_APPCAST="$TMP/missing" CODEXBAR_USE_KEYCHAIN_WRAPPER=0 \
  "$ROOT/scripts/generate-update-artifacts.sh" \
    --version 1.2.3 \
    --archive "$ARCHIVE" \
    --notes "$NOTES" \
    --download-prefix "https://github.com/HemSoft/codexbar-mac/releases/download/v1.2.3/" \
    --release-page-url "https://github.com/HemSoft/codexbar-mac/releases/tag/v1.2.3" \
    --appcast-output "$TMP/missing.xml" \
    --cask-output "$TMP/missing.rb" >/dev/null 2>&1
then
  echo "expected a missing Sparkle generator to fail" >&2
  exit 1
fi

if FAKE_UNSIGNED_CURRENT_ITEM=1 \
  CODEXBAR_GENERATE_APPCAST="$FAKE_GENERATOR" \
  CODEXBAR_USE_KEYCHAIN_WRAPPER=0 \
  "$ROOT/scripts/generate-update-artifacts.sh" \
    --version 1.2.3 \
    --archive "$ARCHIVE" \
    --notes "$NOTES" \
    --download-prefix "https://github.com/HemSoft/codexbar-mac/releases/download/v1.2.3/" \
    --release-page-url "https://github.com/HemSoft/codexbar-mac/releases/tag/v1.2.3" \
    --appcast-output "$TMP/unsigned-current.xml" \
    --cask-output "$TMP/unsigned-current.rb" >/dev/null 2>&1
then
  echo "expected a current item without archive and notes signatures to fail" >&2
  exit 1
fi

mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf 'called\n' >>"$CALL_LOG"
exit 99
EOF
chmod +x "$TMP/bin/gh"

PATH="$TMP/bin:$PATH" "$ROOT/scripts/publish-github-pages-appcast.sh" \
  --appcast "$APPCAST" \
  --version 1.2.3 \
  --dry-run >/dev/null
[[ ! -e "$CALL_LOG" ]] || {
  echo "dry-run unexpectedly contacted GitHub" >&2
  exit 1
}

cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$CALL_LOG"
if [[ "\$*" == "api repos/HemSoft/codexbar-mac/pages" ]]; then
  printf '%s\n' '{"source":{"branch":"gh-pages","path":"/docs"}}'
  exit 0
fi
exit 99
EOF
chmod +x "$TMP/bin/gh"
if PATH="$TMP/bin:$PATH" "$ROOT/scripts/publish-github-pages-appcast.sh" \
  --appcast "$APPCAST" \
  --version 1.2.3 >/dev/null 2>&1
then
  echo "expected a conflicting GitHub Pages source path to fail" >&2
  exit 1
fi

printf '<rss><channel/></rss>\n' >"$TMP/unsigned-appcast.xml"
if "$ROOT/scripts/publish-github-pages-appcast.sh" \
  --appcast "$TMP/unsigned-appcast.xml" \
  --version 1.2.3 \
  --dry-run >/dev/null 2>&1
then
  echo "expected unsigned appcast publication to fail" >&2
  exit 1
fi

echo "scripts/test-release-artifacts.sh passed"
