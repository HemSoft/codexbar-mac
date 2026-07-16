#!/usr/bin/env bash
# Generate a Certificate Signing Request for a Developer ID Application certificate.
# The private key is created inside the dedicated CodexBar signing keychain.
#
# After running:
#   1. Upload dist/CodexBarMac-DeveloperID.certSigningRequest at
#      https://developer.apple.com/account/resources/certificates/add
#      (type: Developer ID Application)
#   2. Download the .cer and import it into the signing keychain:
#        ./scripts/with-codexbar-keychain.sh security import ~/Downloads/*.cer \
#          -k "$HOME/Library/Keychains/codexbar-dev.keychain-db"
#   3. Verify:
#        ./scripts/with-codexbar-keychain.sh security find-identity -v -p codesigning

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/dist"
CSR_PATH="$OUT_DIR/CodexBarMac-DeveloperID.certSigningRequest"
KEY_NAME="CodexBar Mac Developer ID Application"
EMAIL="${CODEXBAR_CSR_EMAIL:-}"
COMMON_NAME="${CODEXBAR_CSR_COMMON_NAME:-CodexBar Mac Developer ID}"
SIGNING_KEYCHAIN="${CODEXBAR_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/codexbar-dev.keychain-db}"
export CODEXBAR_SIGNING_KEYCHAIN="$SIGNING_KEYCHAIN"

mkdir -p "$OUT_DIR"
"$ROOT/scripts/unlock-codexbar-keychain.sh"

if [[ -z "$EMAIL" ]]; then
  EMAIL="$(git -C "$ROOT" config user.email 2>/dev/null || true)"
fi
[[ -n "$EMAIL" ]] || {
  echo "Set CODEXBAR_CSR_EMAIL or git user.email for the CSR email field." >&2
  exit 1
}

# Create the key pair in the signing keychain, then emit a CSR to disk.
"$ROOT/scripts/with-codexbar-keychain.sh" security delete-key -a "$KEY_NAME" \
  "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true

"$ROOT/scripts/with-codexbar-keychain.sh" /usr/bin/openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$OUT_DIR/CodexBarMac-DeveloperID.key" \
  -out "$CSR_PATH" \
  -subj "/emailAddress=${EMAIL}/CN=${COMMON_NAME}/C=US"

# Prefer keeping the private key in the keychain rather than a plaintext file.
# Import then delete the on-disk key if import succeeds.
if "$ROOT/scripts/with-codexbar-keychain.sh" security import \
  "$OUT_DIR/CodexBarMac-DeveloperID.key" \
  -k "$SIGNING_KEYCHAIN" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null 2>&1; then
  rm -f "$OUT_DIR/CodexBarMac-DeveloperID.key"
  echo "Imported private key into $SIGNING_KEYCHAIN and removed the on-disk key."
else
  echo "WARNING: Could not import the private key into the signing keychain." >&2
  echo "Keep $OUT_DIR/CodexBarMac-DeveloperID.key secure and never commit it." >&2
fi

chmod 600 "$CSR_PATH" 2>/dev/null || true
echo "CSR written to $CSR_PATH"
echo "Upload it as a Developer ID Application certificate, then import the .cer:"
echo "  ./scripts/with-codexbar-keychain.sh security import ~/Downloads/<cert>.cer \\"
echo "    -k \"$SIGNING_KEYCHAIN\""
echo "Verify with:"
echo "  ./scripts/with-codexbar-keychain.sh security find-identity -v -p codesigning"
