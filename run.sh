#!/usr/bin/env bash
set -euo pipefail

PROJECT="CodexBarMac.xcodeproj"
SCHEME="CodexBarMac"
BUNDLE_ID="com.hemsoft.CodexBarMac"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$(dirname "$0")"

if [[ ! -d "$DEVELOPER_DIR" ]]; then
  echo "Xcode developer directory not found: $DEVELOPER_DIR" >&2
  exit 1
fi

export DEVELOPER_DIR

echo "Building $SCHEME"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -quiet \
  build

BUILD_DIR="$(xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -showBuildSettings \
  2>/dev/null | awk -F'= ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}')"

APP_PATH="$BUILD_DIR/$SCHEME.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found: $APP_PATH" >&2
  exit 1
fi

echo "Launching $APP_PATH"
open "$APP_PATH"

echo "CodexBar is running ($BUNDLE_ID). Look for the chart.bar icon in the menu bar."
