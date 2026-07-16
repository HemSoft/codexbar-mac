#!/usr/bin/env bash
set -euo pipefail

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_KEYCHAIN="$HOME/Library/Keychains/codexbar-dev.keychain-db"
PASSWORD_DIR="$HOME/Library/Application Support/CodexBar"
PASSWORD_FILE="$PASSWORD_DIR/signing-keychain-password"
BACKUP_DIR="$HOME/Library/Developer/Xcode/UserData/CodexBarSigningBackups/keychains"

new_password="$(osascript <<'OSA'
with timeout of 3600 seconds
  set dialogResult to display dialog "Choose a password for the new CodexBar signing keychain." default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" giving up after 3600
  if gave up of dialogResult then error number -128
  return text returned of dialogResult
end timeout
OSA
)"

confirmation="$(osascript <<'OSA'
with timeout of 3600 seconds
  set dialogResult to display dialog "Enter the same CodexBar signing keychain password again." default answer "" with hidden answer buttons {"Cancel", "Continue"} default button "Continue" cancel button "Cancel" giving up after 3600
  if gave up of dialogResult then error number -128
  return text returned of dialogResult
end timeout
OSA
)"

[[ -n "$new_password" ]] || {
  echo "The CodexBar signing keychain password cannot be empty." >&2
  exit 1
}
[[ "$new_password" == "$confirmation" ]] || {
  echo "The two password entries did not match." >&2
  exit 1
}

mkdir -p "$BACKUP_DIR" "$PASSWORD_DIR"
chmod 700 "$PASSWORD_DIR"

if [[ -e "$SIGNING_KEYCHAIN" ]]; then
  backup="$BACKUP_DIR/codexbar-dev-reset-$(date +%Y%m%d-%H%M%S).keychain-db"
  mv "$SIGNING_KEYCHAIN" "$backup"
  echo "Backed up the previous signing keychain to $backup"
fi

security create-keychain -p "$new_password" "$SIGNING_KEYCHAIN"
security set-keychain-settings -lut 21600 "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$new_password" "$SIGNING_KEYCHAIN"

umask 077
printf '%s' "$new_password" >"$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

# Preserve any existing user keychains; only ensure login stays default and
# the new signing keychain stays out of the normal search list.
EXISTING=()
while IFS= read -r line; do
  line="${line%\"}"
  line="${line#\"}"
  [[ -z "$line" ]] && continue
  [[ "$line" == "$SIGNING_KEYCHAIN" ]] && continue
  EXISTING+=("$line")
done < <(security list-keychains -d user)
if [[ ${#EXISTING[@]} -eq 0 ]]; then
  EXISTING=("$LOGIN_KEYCHAIN" /Library/Keychains/System.keychain)
fi
security list-keychains -d user -s "${EXISTING[@]}"
security default-keychain -d user -s "$LOGIN_KEYCHAIN"

unset new_password confirmation

"$(dirname "$0")/unlock-codexbar-keychain.sh"
echo "Created and verified a clean CodexBar signing keychain."
