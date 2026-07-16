#!/usr/bin/env bash
# Build, Developer ID–sign, notarize, staple, and package CodexBar for Mac.
#
# Prerequisites (local machine only — never commit these):
#   - Dedicated signing keychain at ~/Library/Keychains/codexbar-dev.keychain-db
#   - Developer ID Application certificate for team W2A23PX5BP in that keychain
#   - notarytool credentials profile (default name: codexbar-notary)
#
# Usage:
#   ./scripts/release.sh [--version 1.0] [--skip-notarize] [--publish] [--dry-run]
#
# Default output: dist/CodexBarMac-<version>.zip containing CodexBarMac.app

set -euo pipefail

# Ensure Apple CLI tools are findable even in minimal agent shells.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:${PATH:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROJECT="CodexBarMac.xcodeproj"
SCHEME="CodexBarMac"
TEAM_ID="${CODEXBAR_TEAM_ID:-W2A23PX5BP}"
NOTARY_PROFILE="${CODEXBAR_NOTARY_PROFILE:-codexbar-notary}"
SIGNING_IDENTITY_QUERY="${CODEXBAR_SIGNING_IDENTITY:-Developer ID Application}"
SIGNING_KEYCHAIN="${CODEXBAR_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/codexbar-dev.keychain-db}"
export CODEXBAR_SIGNING_KEYCHAIN="$SIGNING_KEYCHAIN"
DIST_DIR="$ROOT/dist"
DERIVED_DATA="$DIST_DIR/DerivedData"
VERSION=""
SKIP_NOTARIZE=0
PUBLISH=0
DRY_RUN=0

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/release.sh [options]

Options:
  --version <ver>     Marketing version (default: MARKETING_VERSION from the project)
  --skip-notarize     Sign and zip without notarytool (not Gatekeeper-clean)
  --publish           After packaging, create/update GitHub Release v<ver>
  --dry-run           Print the plan and verify prerequisites; do not build
  -h, --help          Show this help
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
    --skip-notarize)
      SKIP_NOTARIZE=1
      shift
      ;;
    --publish)
      PUBLISH=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [[ -z "$DEVELOPER_DIR" || ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory not found. Set DEVELOPER_DIR or run xcode-select -s <path>." >&2
  exit 1
fi
if [[ "$DEVELOPER_DIR" == "/Library/Developer/CommandLineTools" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export DEVELOPER_DIR

if [[ -z "$VERSION" ]]; then
  VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/MARKETING_VERSION/ {print $2; exit}' \
    | tr -d '[:space:]')"
fi
[[ -n "$VERSION" ]] || {
  echo "Could not determine marketing version." >&2
  exit 1
}

ARCHIVE_PATH="$DIST_DIR/CodexBarMac-$VERSION.xcarchive"
APP_NAME="CodexBarMac.app"
EXPORT_DIR="$DIST_DIR/export-$VERSION"
ZIP_PATH="$DIST_DIR/CodexBarMac-$VERSION.zip"
NOTES_PATH="$DIST_DIR/CodexBarMac-$VERSION-notes.md"

echo "CodexBar Mac release"
echo "  version:         $VERSION"
echo "  team:            $TEAM_ID"
echo "  notary profile:  $NOTARY_PROFILE"
echo "  skip notarize:   $SKIP_NOTARIZE"
echo "  publish:         $PUBLISH"
echo "  dry run:         $DRY_RUN"
echo

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_cmd xcodebuild
require_cmd codesign
require_cmd ditto
require_cmd python3

if [[ "$PUBLISH" -eq 1 ]]; then
  require_cmd gh
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  require_cmd spctl
fi

if [[ "$SKIP_NOTARIZE" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
  require_cmd xcrun
fi

echo "Unlocking CodexBar signing keychain..."
"$ROOT/scripts/unlock-codexbar-keychain.sh"

IDENTITY="$("$ROOT/scripts/with-codexbar-keychain.sh" security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" \
  | awk -v q="$SIGNING_IDENTITY_QUERY" -v team="$TEAM_ID" 'index($0, q) && index($0, team) && $0 !~ /CSSMERR_/ {print; exit}')"

if [[ -z "$IDENTITY" ]]; then
  cat >&2 <<EOF
No valid "$SIGNING_IDENTITY_QUERY" identity for team $TEAM_ID found in:
  $SIGNING_KEYCHAIN

Create a Developer ID Application certificate for team $TEAM_ID in the Apple
Developer portal, install it into the dedicated signing keychain
(via ./scripts/with-codexbar-keychain.sh), then re-run this script.

Current codesigning identities in that keychain:
EOF
  "$ROOT/scripts/with-codexbar-keychain.sh" security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" >&2 || true
  exit 1
fi

IDENTITY_HASH="$(awk '{print $2}' <<<"$IDENTITY")"
IDENTITY_NAME="$(sed -E 's/.*"([^"]+)".*/\1/' <<<"$IDENTITY")"
echo "Using signing identity: $IDENTITY_NAME ($IDENTITY_HASH)"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
notarytool profile "$NOTARY_PROFILE" is missing or invalid.

Store credentials once (interactive; do not commit secrets):

  xcrun notarytool store-credentials "$NOTARY_PROFILE" --apple-id <apple-id> --team-id $TEAM_ID

Or use an App Store Connect API key:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
    --key ~/path/to/AuthKey_XXXXXX.p8 --key-id XXXXXX --issuer <issuer-uuid>
EOF
    exit 1
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run OK — prerequisites satisfied."
  exit 0
fi

mkdir -p "$DIST_DIR"
rm -rf "$DERIVED_DATA" "$ARCHIVE_PATH" "$EXPORT_DIR" "$ZIP_PATH" "$NOTES_PATH"

echo "Cutting release notes from CHANGELOG.md..."
"$ROOT/scripts/cut-changelog.sh" --notes-out "$NOTES_PATH" "$VERSION"

echo "Building Release archive..."
"$ROOT/scripts/with-codexbar-keychain.sh" xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY_NAME" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"
[[ -d "$APP_PATH" ]] || {
  echo "Archived app missing at $APP_PATH" >&2
  exit 1
}

echo "Deep-signing $APP_NAME..."
"$ROOT/scripts/with-codexbar-keychain.sh" codesign \
  --force \
  --deep \
  --options runtime \
  --timestamp \
  --entitlements "$ROOT/CodexBarMac/CodexBarMac.entitlements" \
  --sign "$IDENTITY_HASH" \
  "$APP_PATH"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$EXPORT_DIR"
ditto "$APP_PATH" "$EXPORT_DIR/$APP_NAME"

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  echo "Submitting zip for notarization..."
  SUBMIT_ZIP="$DIST_DIR/CodexBarMac-$VERSION-submit.zip"
  rm -f "$SUBMIT_ZIP"
  ditto -c -k --keepParent "$EXPORT_DIR/$APP_NAME" "$SUBMIT_ZIP"

  xcrun notarytool submit "$SUBMIT_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "Stapling notarization ticket..."
  xcrun stapler staple "$EXPORT_DIR/$APP_NAME"
  xcrun stapler validate "$EXPORT_DIR/$APP_NAME"
  spctl --assess --type execute --verbose=4 "$EXPORT_DIR/$APP_NAME" || {
    echo "spctl assessment reported an issue; inspect Gatekeeper output above." >&2
    exit 1
  }
  rm -f "$SUBMIT_ZIP"
else
  echo "Skipping notarization (--skip-notarize)."
fi

echo "Creating distribution zip..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$EXPORT_DIR/$APP_NAME" "$ZIP_PATH"

echo
echo "Packaged: $ZIP_PATH"
echo "Notes:    $NOTES_PATH"

if [[ "$PUBLISH" -eq 1 ]]; then
  TAG="v$VERSION"
  TARGET_SHA="$(git -C "$ROOT" rev-parse HEAD)"
  echo "Publishing GitHub Release $TAG at $TARGET_SHA..."
  if gh release view "$TAG" >/dev/null 2>&1; then
    # Prefer the peeled commit SHA for annotated tags (refs/tags/vX^{}).
    TAG_SHA="$(
      git ls-remote --tags origin "refs/tags/${TAG}^{}" 2>/dev/null | awk '{print $1; exit}'
    )"
    if [[ -z "$TAG_SHA" ]]; then
      TAG_SHA="$(
        git ls-remote --tags origin "refs/tags/${TAG}" 2>/dev/null | awk '{print $1; exit}'
      )"
    fi
    if [[ -n "$TAG_SHA" && "$TAG_SHA" != "$TARGET_SHA" ]]; then
      echo "Remote tag $TAG points at $TAG_SHA, but this build is $TARGET_SHA." >&2
      echo "Move the tag to HEAD before republishing assets, for example:" >&2
      echo "  git tag -f $TAG $TARGET_SHA && git push -f origin refs/tags/$TAG" >&2
      exit 1
    fi
    gh release upload "$TAG" "$ZIP_PATH" --clobber
    gh release edit "$TAG" \
      --notes-file "$NOTES_PATH" \
      --target "$TARGET_SHA"
  else
    gh release create "$TAG" "$ZIP_PATH" \
      --title "CodexBar for Mac $VERSION" \
      --notes-file "$NOTES_PATH" \
      --target "$TARGET_SHA"
  fi
  echo "Published: $(gh release view "$TAG" --json url --jq .url)"
fi

echo "Done."
