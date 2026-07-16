#!/usr/bin/env bash
set -euo pipefail

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_KEYCHAIN="${CODEXBAR_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/codexbar-dev.keychain-db}"
SYSTEM_KEYCHAIN="/Library/Keychains/System.keychain"
PASSWORD_FILE="$HOME/Library/Application Support/CodexBar/signing-keychain-password"

normalize_keychain_path() {
  # security list-keychains prints indented quoted paths, e.g. `    "/path"`.
  printf '%s' "$1" | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//'
}

[[ -f "$LOGIN_KEYCHAIN" ]] || {
  echo "Login keychain is missing: $LOGIN_KEYCHAIN" >&2
  exit 1
}
[[ -f "$SIGNING_KEYCHAIN" ]] || {
  echo "CodexBar signing keychain is missing: $SIGNING_KEYCHAIN" >&2
  exit 1
}
[[ -f "$PASSWORD_FILE" ]] || {
  echo "CodexBar signing keychain password file is missing: $PASSWORD_FILE" >&2
  exit 1
}

password_mode="$(stat -f '%Lp' "$PASSWORD_FILE")"
if [[ "$password_mode" != "600" ]]; then
  echo "Refusing to read $PASSWORD_FILE because its mode is $password_mode, not 600." >&2
  exit 1
fi

PREVIOUS_DEFAULT_KEYCHAIN="$(security default-keychain -d user 2>/dev/null | sed -E 's/^[[:space:]]*"//; s/"[[:space:]]*$//' || true)"

# Capture the current user search list, then restore it without the lock-on-sleep
# signing keychain. Do not clobber unrelated maintainer keychains.
restore_user_search_list() {
  local -a restored=()
  local line

  while IFS= read -r line; do
    line="$(normalize_keychain_path "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" == "$SIGNING_KEYCHAIN" ]] && continue
    restored+=("$line")
  done < <(security list-keychains -d user)

  if [[ ${#restored[@]} -eq 0 ]]; then
    restored=("$LOGIN_KEYCHAIN" "$SYSTEM_KEYCHAIN")
  fi

  security list-keychains -d user -s "${restored[@]}"
  security default-keychain -d user -s "${PREVIOUS_DEFAULT_KEYCHAIN:-$LOGIN_KEYCHAIN}"
}

restore_user_search_list

password="$(<"$PASSWORD_FILE")"
[[ -n "$password" ]] || {
  echo "CodexBar signing keychain password file is empty: $PASSWORD_FILE" >&2
  exit 1
}

security unlock-keychain -p "$password" "$SIGNING_KEYCHAIN"
if security find-identity -v -p codesigning "$SIGNING_KEYCHAIN" | grep -Eq "^[[:space:]]*[1-9][0-9]* valid identities found"; then
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$password" \
    "$SIGNING_KEYCHAIN" >/dev/null
fi

restore_user_search_list

echo "Unlocked CodexBar signing keychain and kept it out of the normal search list."
