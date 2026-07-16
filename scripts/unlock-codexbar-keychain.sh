#!/usr/bin/env bash
set -euo pipefail

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/codexbar-dev.keychain-db"
PASSWORD_FILE="$HOME/Library/Application Support/CodexBar/signing-keychain-password"

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

# Keep the signing keychain out of the normal search list. It locks on sleep,
# and unrelated macOS services may otherwise prompt for its password when they
# search every configured keychain.
security default-keychain -d user -s "$LOGIN_KEYCHAIN"
security list-keychains -d user -s \
  "$LOGIN_KEYCHAIN" \
  /Library/Keychains/System.keychain

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

security list-keychains -d user -s \
  "$LOGIN_KEYCHAIN" \
  /Library/Keychains/System.keychain
security default-keychain -d user -s "$LOGIN_KEYCHAIN"

echo "Unlocked CodexBar signing keychain and kept it out of the normal search list."
