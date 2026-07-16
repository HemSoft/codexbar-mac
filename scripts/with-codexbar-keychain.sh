#!/usr/bin/env bash
set -euo pipefail

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/codexbar-dev.keychain-db"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

if [[ "$#" -eq 0 ]]; then
  echo "Usage: $0 <command> [arguments...]" >&2
  exit 64
fi

restore_normal_search_list() {
  security list-keychains -d user -s \
    "$LOGIN_KEYCHAIN" \
    "$SYSTEM_KEYCHAIN"
  security default-keychain -d user -s "$LOGIN_KEYCHAIN"
}

trap restore_normal_search_list EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$(dirname "$0")/unlock-codexbar-keychain.sh"
security list-keychains -d user -s \
  "$SIGNING_KEYCHAIN" \
  "$LOGIN_KEYCHAIN" \
  "$SYSTEM_KEYCHAIN"

"$@"
