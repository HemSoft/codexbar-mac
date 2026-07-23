#!/usr/bin/env bash
# Generate the Homebrew tap cask for one immutable CodexBar release archive.
set -euo pipefail

VERSION=""
URL=""
SHA256=""
OUTPUT=""

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/generate-homebrew-cask.sh \
  --version <version> --url <https-url> --sha256 <64-hex-digest> --output <path>
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
    --url)
      [[ $# -ge 2 ]] || usage
      URL="$2"
      shift 2
      ;;
    --sha256)
      [[ $# -ge 2 ]] || usage
      SHA256="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || usage
      OUTPUT="$2"
      shift 2
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

[[ "$VERSION" =~ ^[0-9]+([.][0-9A-Za-z-]+)*$ ]] || {
  echo "Invalid version: $VERSION" >&2
  exit 1
}
[[ "$URL" =~ ^https://github[.]com/HemSoft/codexbar-mac/releases/download/v[^/]+/CodexBarMac-[^/]+[.]zip$ ]] || {
  echo "Release URL must be an immutable CodexBar GitHub Release ZIP URL." >&2
  exit 1
}
[[ "$URL" == "https://github.com/HemSoft/codexbar-mac/releases/download/v$VERSION/CodexBarMac-$VERSION.zip" ]] || {
  echo "Release URL tag and filename must match version $VERSION." >&2
  exit 1
}
[[ "$SHA256" =~ ^[0-9a-fA-F]{64}$ ]] || {
  echo "SHA-256 must contain exactly 64 hexadecimal characters." >&2
  exit 1
}
[[ -n "$OUTPUT" ]] || usage
SHA256="$(printf '%s' "$SHA256" | tr '[:upper:]' '[:lower:]')"

mkdir -p "$(dirname "$OUTPUT")"
cat >"$OUTPUT" <<EOF
cask "codexbar-mac" do
  version "$VERSION"
  sha256 "$SHA256"

  url "$URL"
  name "CodexBar"
  desc "Menu bar display for AI provider usage limits"
  homepage "https://github.com/HemSoft/codexbar-mac"

  auto_updates true
  depends_on macos: ">= :sonoma"

  app "CodexBarMac.app"
end
EOF

echo "Generated Homebrew cask: $OUTPUT"
