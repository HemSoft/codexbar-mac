#!/usr/bin/env bash
set -euo pipefail

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/codexbar-dev.keychain-db"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"

if [[ "$#" -eq 0 ]]; then
  echo "Usage: $0 <command> [arguments...]" >&2
  exit 64
fi

ORIGINAL_SEARCH_LIST=()
while IFS= read -r line; do
  line="${line%\"}"
  line="${line#\"}"
  [[ -z "$line" ]] && continue
  ORIGINAL_SEARCH_LIST+=("$line")
done < <(security list-keychains -d user)

restore_normal_search_list() {
  local -a restored=()
  local kc

  for kc in "${ORIGINAL_SEARCH_LIST[@]}"; do
    [[ "$kc" == "$SIGNING_KEYCHAIN" ]] && continue
    restored+=("$kc")
  done

  if [[ ${#restored[@]} -eq 0 ]]; then
    restored=("$LOGIN_KEYCHAIN" "$SYSTEM_KEYCHAIN")
  fi

  security list-keychains -d user -s "${restored[@]}"
  security default-keychain -d user -s "$LOGIN_KEYCHAIN"
}

trap restore_normal_search_list EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$(dirname "$0")/unlock-codexbar-keychain.sh"

PRIOR_WITHOUT_SIGNING=()
for kc in "${ORIGINAL_SEARCH_LIST[@]}"; do
  [[ "$kc" == "$SIGNING_KEYCHAIN" ]] && continue
  PRIOR_WITHOUT_SIGNING+=("$kc")
done
if [[ ${#PRIOR_WITHOUT_SIGNING[@]} -eq 0 ]]; then
  PRIOR_WITHOUT_SIGNING=("$LOGIN_KEYCHAIN" "$SYSTEM_KEYCHAIN")
fi

security list-keychains -d user -s \
  "$SIGNING_KEYCHAIN" \
  "${PRIOR_WITHOUT_SIGNING[@]}"

"$@"
