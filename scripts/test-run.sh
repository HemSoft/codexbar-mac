#!/usr/bin/env bash
# Smoke-test run.sh's Xcode selection without building or launching the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
BUILD_DIR="$TMP/build"
CALL_LOG="$TMP/calls.txt"
mkdir -p "$FAKE_BIN" "$BUILD_DIR"

cat >"$FAKE_BIN/xcode-select" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "-p" ]]
printf '%s\n' "/Library/Developer/CommandLineTools"
EOF

cat >"$FAKE_BIN/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodebuild DEVELOPER_DIR=%s ARGS=%s\n' "${DEVELOPER_DIR:-}" "$*" >>"$CODEXBAR_RUN_TEST_LOG"
if [[ " $* " == *" -showBuildSettings "* ]]; then
  printf '    BUILT_PRODUCTS_DIR = %s\n' "$CODEXBAR_RUN_TEST_BUILD_DIR"
else
  mkdir -p "$CODEXBAR_RUN_TEST_BUILD_DIR/CodexBarMac.app"
fi
EOF

cat >"$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

cat >"$FAKE_BIN/open" <<'EOF'
#!/usr/bin/env bash
printf 'open %s\n' "$*" >>"$CODEXBAR_RUN_TEST_LOG"
EOF

chmod +x "$FAKE_BIN/xcode-select" "$FAKE_BIN/xcodebuild" "$FAKE_BIN/pgrep" "$FAKE_BIN/open"

if [[ ! -d /Applications/Xcode.app/Contents/Developer ]]; then
  echo "run.sh smoke test requires /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

env -u DEVELOPER_DIR \
  PATH="$FAKE_BIN:$PATH" \
  CODEXBAR_RUN_TEST_BUILD_DIR="$BUILD_DIR" \
  CODEXBAR_RUN_TEST_LOG="$CALL_LOG" \
  "$ROOT/run.sh" >/dev/null

EXPECTED_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
[[ "$(grep -c "^xcodebuild DEVELOPER_DIR=$EXPECTED_DEVELOPER_DIR " "$CALL_LOG")" -eq 2 ]]
grep -Fqx "open $BUILD_DIR/CodexBarMac.app" "$CALL_LOG"

CUSTOM_DEVELOPER_DIR="$TMP/CustomXcode.app/Contents/Developer"
mkdir -p "$CUSTOM_DEVELOPER_DIR"
: >"$CALL_LOG"

DEVELOPER_DIR="$CUSTOM_DEVELOPER_DIR" \
  PATH="$FAKE_BIN:$PATH" \
  CODEXBAR_RUN_TEST_BUILD_DIR="$BUILD_DIR" \
  CODEXBAR_RUN_TEST_LOG="$CALL_LOG" \
  "$ROOT/run.sh" >/dev/null

[[ "$(grep -c "^xcodebuild DEVELOPER_DIR=$CUSTOM_DEVELOPER_DIR " "$CALL_LOG")" -eq 2 ]]

echo "scripts/test-run.sh passed"
