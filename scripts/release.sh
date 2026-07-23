#!/usr/bin/env bash
# Build, sign, notarize, package, and optionally publish CodexBar for Mac.
#
# Prerequisites (local machine only — never commit these):
#   - Dedicated signing keychain at ~/Library/Keychains/codexbar-dev.keychain-db
#   - Developer ID Application certificate for team W2A23PX5BP in that keychain
#   - notarytool credentials profile (default name: codexbar-notary)
#
# Usage:
#   CODEXBAR_SPARKLE_PUBLIC_ED_KEY=<public-key> \
#     ./scripts/release.sh [--version 1.0] [--skip-notarize] [--publish] [--dry-run]
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
SPARKLE_ACCOUNT="${CODEXBAR_SPARKLE_ACCOUNT:-codexbar-mac}"
SPARKLE_PUBLIC_ED_KEY="${CODEXBAR_SPARKLE_PUBLIC_ED_KEY:-}"
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
  --skip-notarize     Sign and zip without notarytool (not Gatekeeper-clean; incompatible with --publish)
  --publish           Publish immutable Release assets, signed appcast, and generated cask
  --dry-run           Print the plan and verify prerequisites; do not build
  -h, --help          Show this help

Non-dry-run releases must run from a clean main branch.
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
[[ "$VERSION" =~ ^[0-9]+([.][0-9A-Za-z-]+)*$ ]] || {
  echo "Invalid release version: $VERSION" >&2
  exit 1
}

ARCHIVE_PATH="$DIST_DIR/CodexBarMac-$VERSION.xcarchive"
APP_NAME="CodexBarMac.app"
EXPORT_DIR="$DIST_DIR/export-$VERSION"
ZIP_PATH="$DIST_DIR/CodexBarMac-$VERSION.zip"
NOTES_PATH="$DIST_DIR/CodexBarMac-$VERSION.md"
APPCAST_PATH="$DIST_DIR/appcast.xml"
CASK_PATH="$DIST_DIR/codexbar-mac.rb"

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
  require_cmd jq
  require_cmd rg
fi

[[ "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
  cat >&2 <<'EOF'
CODEXBAR_SPARKLE_PUBLIC_ED_KEY must contain the base64 EdDSA public key that
matches the CodexBar Sparkle private key. Public keys are safe to place in the
environment; never place the private key there.
EOF
  exit 1
}

if [[ "$PUBLISH" -eq 1 && "$SKIP_NOTARIZE" -eq 1 ]]; then
  echo "Refusing to publish with --skip-notarize. Notarize first, or omit --publish." >&2
  exit 1
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
  CURRENT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "Refusing to release from branch '$CURRENT_BRANCH'. Releases must run from the 'main' branch." >&2
    exit 1
  fi
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    echo "Refusing to release from a dirty worktree. Commit or stash changes first." >&2
    git -C "$ROOT" status --short >&2
    exit 1
  fi
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

if [[ "$PUBLISH" -eq 1 ]]; then
  if ! "$ROOT/scripts/with-codexbar-keychain.sh" security find-generic-password \
    -s "https://sparkle-project.org" \
    -a "$SPARKLE_ACCOUNT" \
    "$SIGNING_KEYCHAIN" >/dev/null 2>&1
  then
    cat >&2 <<EOF
Sparkle EdDSA private key account "$SPARKLE_ACCOUNT" was not found in:
  $SIGNING_KEYCHAIN

Generate or import it with Sparkle's generate_keys tool through:
  CODEXBAR_KEYCHAIN_AS_DEFAULT=1 \\
    ./scripts/with-codexbar-keychain.sh <path-to-generate_keys> --account "$SPARKLE_ACCOUNT"

Never commit or print the private key.
EOF
    exit 1
  fi
fi

if [[ "$SKIP_NOTARIZE" -eq 0 ]]; then
  require_cmd xcrun
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

find_sparkle_tools() {
  local search_root

  if [[ -z "${CODEXBAR_GENERATE_APPCAST:-}" ]]; then
    for search_root in \
      "$DERIVED_DATA/SourcePackages/artifacts" \
      "$HOME/Library/Developer/Xcode/DerivedData"
    do
      [[ -d "$search_root" ]] || continue
      CODEXBAR_GENERATE_APPCAST="$(
        rg --files "$search_root" \
          | rg '/generate_appcast$' \
          | head -1 \
          || true
      )"
      [[ -n "$CODEXBAR_GENERATE_APPCAST" ]] && break
    done
    export CODEXBAR_GENERATE_APPCAST
  fi
  [[ -x "${CODEXBAR_GENERATE_APPCAST:-}" ]] || {
    echo "Sparkle generate_appcast was not found. Resolve the Sparkle package or set CODEXBAR_GENERATE_APPCAST." >&2
    exit 1
  }

  if [[ -z "${CODEXBAR_GENERATE_KEYS:-}" ]]; then
    CODEXBAR_GENERATE_KEYS="$(dirname "$CODEXBAR_GENERATE_APPCAST")/generate_keys"
    export CODEXBAR_GENERATE_KEYS
  fi
  [[ -x "$CODEXBAR_GENERATE_KEYS" ]] || {
    echo "Sparkle generate_keys was not found next to generate_appcast." >&2
    exit 1
  }
}

verify_sparkle_key_pair() {
  local key_summary

  key_summary="$(
    "$ROOT/scripts/with-codexbar-keychain.sh" \
      "$CODEXBAR_GENERATE_KEYS" \
      --account "$SPARKLE_ACCOUNT" \
      -p
  )"
  grep -Fq "$SPARKLE_PUBLIC_ED_KEY" <<<"$key_summary" || {
    echo "CODEXBAR_SPARKLE_PUBLIC_ED_KEY does not match Keychain account \"$SPARKLE_ACCOUNT\"." >&2
    exit 1
  }
}

PREFLIGHT_DIR="$(mktemp -d)"
trap 'rm -rf "$PREFLIGHT_DIR"' EXIT
EXISTING_APPCAST_ARGS=()

preflight_publication_state() {
  local pages_json
  local pages_branch
  local pages_path
  local encoded_appcast
  local gh_pages_ref_count
  local existing_appcast_path="$PREFLIGHT_DIR/existing-appcast.xml"

  [[ "$(gh api repos/HemSoft/codexbar-mac --jq '.permissions.admin')" == "true" ]] || {
    echo "GitHub authentication needs repository admin permission to publish Releases and Pages." >&2
    exit 1
  }

  if pages_json="$(gh api repos/HemSoft/codexbar-mac/pages 2>/dev/null)"; then
    pages_branch="$(jq -r '.source.branch // empty' <<<"$pages_json")"
    pages_path="$(jq -r '.source.path // empty' <<<"$pages_json")"
    [[ "$pages_branch" == "gh-pages" && "$pages_path" == "/" ]] || {
      echo "GitHub Pages must publish the root of the gh-pages branch; refusing to change existing settings." >&2
      exit 1
    }
  fi

  gh_pages_ref_count="$(
    gh api repos/HemSoft/codexbar-mac/git/matching-refs/heads/gh-pages --jq length
  )" || {
    echo "Could not determine whether the gh-pages branch exists; refusing to publish." >&2
    exit 1
  }

  if [[ "$gh_pages_ref_count" -gt 0 ]]; then
    encoded_appcast="$(
      gh api "repos/HemSoft/codexbar-mac/contents/appcast.xml?ref=gh-pages" --jq .content
    )" || {
      echo "The gh-pages branch exists, but its appcast could not be read; refusing to reset update history." >&2
      exit 1
    }
    python3 -c \
      'import base64,sys; sys.stdout.buffer.write(base64.b64decode(sys.stdin.read()))' \
      <<<"$encoded_appcast" >"$existing_appcast_path"
    grep -Fq '<!-- sparkle-signatures:' "$existing_appcast_path" || {
      echo "Existing gh-pages appcast is not a signed feed; refusing to discard or replace its history." >&2
      exit 1
    }
    EXISTING_APPCAST_ARGS=(--existing-appcast "$existing_appcast_path")
  fi
}

if [[ "$PUBLISH" -eq 1 ]]; then
  preflight_publication_state
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$PUBLISH" -eq 1 ]]; then
    find_sparkle_tools
    verify_sparkle_key_pair
  fi
  echo "Dry run OK — prerequisites satisfied."
  exit 0
fi

mkdir -p "$DIST_DIR"
rm -rf "$DERIVED_DATA" "$ARCHIVE_PATH" "$EXPORT_DIR" "$ZIP_PATH" "$NOTES_PATH" "$APPCAST_PATH" "$CASK_PATH"

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
  SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
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

  find_sparkle_tools
  verify_sparkle_key_pair

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
    echo "Move the tag to HEAD before publishing assets, for example:" >&2
    echo "  git tag -f $TAG $TARGET_SHA && git push -f origin refs/tags/$TAG" >&2
    exit 1
  fi

  release_asset_json() {
    local tag="$1"
    local asset_name="$2"

    gh api "repos/HemSoft/codexbar-mac/releases/tags/$tag" \
      | jq -c --arg name "$asset_name" \
        '[.assets[]? | select(.name == $name)][0] // empty'
  }

  REMOTE_ASSET_DIR="$DIST_DIR/remote-$VERSION"
  rm -rf "$REMOTE_ASSET_DIR"
  mkdir -p "$REMOTE_ASSET_DIR"

  if gh release view "$TAG" >/dev/null 2>&1; then
    ZIP_ASSET_JSON="$(release_asset_json "$TAG" "$(basename "$ZIP_PATH")")"
    if [[ -n "$ZIP_ASSET_JSON" ]]; then
      echo "Using the existing immutable release ZIP for resumed publication."
      gh release download "$TAG" \
        --pattern "$(basename "$ZIP_PATH")" \
        --dir "$REMOTE_ASSET_DIR"
      PUBLISHED_ZIP_PATH="$REMOTE_ASSET_DIR/$(basename "$ZIP_PATH")"
      REMOTE_ZIP_DIGEST="$(jq -r '.digest // empty' <<<"$ZIP_ASSET_JSON" | sed -E 's/^sha256://')"
      DOWNLOADED_ZIP_DIGEST="$(shasum -a 256 "$PUBLISHED_ZIP_PATH" | awk '{print $1}')"
      if [[ -n "$REMOTE_ZIP_DIGEST" && "$REMOTE_ZIP_DIGEST" != "$DOWNLOADED_ZIP_DIGEST" ]]; then
        echo "Downloaded release ZIP does not match GitHub's recorded digest." >&2
        exit 1
      fi
    else
      gh release upload "$TAG" "$ZIP_PATH"
      PUBLISHED_ZIP_PATH="$ZIP_PATH"
    fi
  else
    gh release create "$TAG" "$ZIP_PATH" \
      --title "CodexBar for Mac $VERSION" \
      --notes-file "$NOTES_PATH" \
      --target "$TARGET_SHA"
    PUBLISHED_ZIP_PATH="$ZIP_PATH"
  fi

  REMOTE_NOTES_PRESENT=0
  NOTES_ASSET_JSON="$(release_asset_json "$TAG" "$(basename "$NOTES_PATH")")"
  if [[ -n "$NOTES_ASSET_JSON" ]]; then
    REMOTE_NOTES_PRESENT=1
    gh release download "$TAG" \
      --pattern "$(basename "$NOTES_PATH")" \
      --dir "$REMOTE_ASSET_DIR"
    NOTES_FOR_APPCAST="$REMOTE_ASSET_DIR/$(basename "$NOTES_PATH")"
    REMOTE_NOTES_DIGEST="$(shasum -a 256 "$NOTES_FOR_APPCAST" | awk '{print $1}')"
    echo "Using the existing immutable signed release notes for resumed publication."
  else
    NOTES_FOR_APPCAST="$NOTES_PATH"
    REMOTE_NOTES_DIGEST=""
  fi

  gh release edit "$TAG" \
    --notes-file "$NOTES_FOR_APPCAST" \
    --target "$TARGET_SHA"

  RELEASE_URL="$(gh release view "$TAG" --json url --jq .url)"
  DOWNLOAD_PREFIX="https://github.com/HemSoft/codexbar-mac/releases/download/$TAG/"

  "$ROOT/scripts/generate-update-artifacts.sh" \
    --version "$VERSION" \
    --archive "$PUBLISHED_ZIP_PATH" \
    --notes "$NOTES_FOR_APPCAST" \
    --download-prefix "$DOWNLOAD_PREFIX" \
    --release-page-url "$RELEASE_URL" \
    --appcast-output "$APPCAST_PATH" \
    --cask-output "$CASK_PATH" \
    "${EXISTING_APPCAST_ARGS[@]}"

  if [[ "$REMOTE_NOTES_PRESENT" -eq 1 ]]; then
    GENERATED_NOTES_DIGEST="$(shasum -a 256 "$NOTES_FOR_APPCAST" | awk '{print $1}')"
    if [[ "$GENERATED_NOTES_DIGEST" != "$REMOTE_NOTES_DIGEST" ]]; then
      echo "Refusing to replace immutable signed release notes after appcast generation." >&2
      exit 1
    fi
  else
    gh release upload "$TAG" "$NOTES_FOR_APPCAST"
  fi

  "$ROOT/scripts/publish-github-pages-appcast.sh" \
    --appcast "$APPCAST_PATH" \
    --version "$VERSION"

  echo "Published release: $RELEASE_URL"
  echo "Published appcast: https://hemsoft.github.io/codexbar-mac/appcast.xml"
  echo "Generated cask:    $CASK_PATH"
  echo "Open a reviewed PR adding it to HemSoft/homebrew-tap after that repository exists."
fi

echo "Done."
