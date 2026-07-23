#!/usr/bin/env bash
set -euo pipefail

PROJECT="CodexBarMac.xcodeproj"
SCHEME="CodexBarMac"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"

if [[ -z "$DEVELOPER_DIR" || ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory not found. Set DEVELOPER_DIR or run xcode-select -s <path>." >&2
  exit 1
fi

if [[ "$DEVELOPER_DIR" == "/Library/Developer/CommandLineTools" ]]; then
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
  else
    echo "Active developer directory is Command Line Tools only. Install Xcode or set DEVELOPER_DIR." >&2
    exit 1
  fi
fi

cd "$(dirname "$0")"

export DEVELOPER_DIR

"./scripts/test-cut-changelog.sh"
"./scripts/test-release-artifacts.sh"

echo "Testing $SCHEME (DEVELOPER_DIR=$DEVELOPER_DIR)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination 'platform=macOS' \
  -configuration Debug \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  test
