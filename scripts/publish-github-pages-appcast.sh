#!/usr/bin/env bash
# Publish an already-signed appcast to the root of the repository's gh-pages branch.
set -euo pipefail

REPOSITORY="HemSoft/codexbar-mac"
APPCAST=""
VERSION=""
DRY_RUN=0

usage() {
  cat >&2 <<'EOF'
Usage: ./scripts/publish-github-pages-appcast.sh \
  --appcast <signed-appcast.xml> --version <version> [--repository owner/repo] [--dry-run]
EOF
  exit 64
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --appcast)
      [[ $# -ge 2 ]] || usage
      APPCAST="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || usage
      VERSION="$2"
      shift 2
      ;;
    --repository)
      [[ $# -ge 2 ]] || usage
      REPOSITORY="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
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

[[ -f "$APPCAST" ]] || {
  echo "Signed appcast is missing: $APPCAST" >&2
  exit 1
}
[[ "$VERSION" =~ ^[0-9]+([.][0-9A-Za-z-]+)*$ ]] || {
  echo "Invalid version: $VERSION" >&2
  exit 1
}
[[ "$REPOSITORY" == "HemSoft/codexbar-mac" ]] || {
  echo "This publisher is restricted to HemSoft/codexbar-mac." >&2
  exit 1
}
grep -Fq 'sparkle:edSignature=' "$APPCAST" || {
  echo "Refusing to publish an appcast without an archive EdDSA signature." >&2
  exit 1
}
grep -Fq '<!-- sparkle-signatures:' "$APPCAST" || {
  echo "Refusing to publish an appcast without a signed-feed block." >&2
  exit 1
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "Dry run: would publish signed appcast for v$VERSION to $REPOSITORY gh-pages."
  exit 0
fi

command -v gh >/dev/null 2>&1 || {
  echo "Missing required command: gh" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || {
  echo "Missing required command: jq" >&2
  exit 1
}

PAGES_EXISTS=0
if PAGES_JSON="$(gh api "repos/$REPOSITORY/pages" 2>/dev/null)"; then
  PAGES_EXISTS=1
  PAGES_BRANCH="$(jq -r '.source.branch // empty' <<<"$PAGES_JSON")"
  PAGES_PATH="$(jq -r '.source.path // empty' <<<"$PAGES_JSON")"
  [[ "$PAGES_BRANCH" == "gh-pages" ]] || {
    echo "GitHub Pages exists but is not configured from gh-pages; refusing to change it." >&2
    exit 1
  }
  [[ "$PAGES_PATH" == "/" ]] || {
    echo "GitHub Pages exists but is not configured from the gh-pages root; refusing to change it." >&2
    exit 1
  }
fi

APPCAST_CONTENT="$(base64 <"$APPCAST" | tr -d '\n')"
COMMIT_MESSAGE="Publish Sparkle appcast for v$VERSION"

if gh api "repos/$REPOSITORY/git/ref/heads/gh-pages" >/dev/null 2>&1; then
  EXISTING_SHA="$(
    gh api "repos/$REPOSITORY/contents/appcast.xml?ref=gh-pages" --jq .sha 2>/dev/null || true
  )"
  if [[ -n "$EXISTING_SHA" ]]; then
    jq -n \
      --arg message "$COMMIT_MESSAGE" \
      --arg content "$APPCAST_CONTENT" \
      --arg branch "gh-pages" \
      --arg sha "$EXISTING_SHA" \
      '{message:$message, content:$content, branch:$branch, sha:$sha}' \
      | gh api --method PUT "repos/$REPOSITORY/contents/appcast.xml" --input - >/dev/null
  else
    jq -n \
      --arg message "$COMMIT_MESSAGE" \
      --arg content "$APPCAST_CONTENT" \
      --arg branch "gh-pages" \
      '{message:$message, content:$content, branch:$branch}' \
      | gh api --method PUT "repos/$REPOSITORY/contents/appcast.xml" --input - >/dev/null
  fi

  if ! gh api "repos/$REPOSITORY/contents/.nojekyll?ref=gh-pages" >/dev/null 2>&1; then
    jq -n \
      --arg message "Configure GitHub Pages for Sparkle" \
      --arg content "" \
      --arg branch "gh-pages" \
      '{message:$message, content:$content, branch:$branch}' \
      | gh api --method PUT "repos/$REPOSITORY/contents/.nojekyll" --input - >/dev/null
  fi
else
  APPCAST_BLOB="$(
    gh api --method POST "repos/$REPOSITORY/git/blobs" \
      -f content="$APPCAST_CONTENT" \
      -f encoding=base64 \
      --jq .sha
  )"
  NOJEKYLL_BLOB="$(
    gh api --method POST "repos/$REPOSITORY/git/blobs" \
      -f content="" \
      -f encoding=utf-8 \
      --jq .sha
  )"
  TREE_SHA="$(
    jq -n \
      --arg appcast "$APPCAST_BLOB" \
      --arg nojekyll "$NOJEKYLL_BLOB" \
      '{tree:[
        {path:"appcast.xml", mode:"100644", type:"blob", sha:$appcast},
        {path:".nojekyll", mode:"100644", type:"blob", sha:$nojekyll}
      ]}' \
      | gh api --method POST "repos/$REPOSITORY/git/trees" --input - --jq .sha
  )"
  COMMIT_SHA="$(
    jq -n \
      --arg message "$COMMIT_MESSAGE" \
      --arg tree "$TREE_SHA" \
      '{message:$message, tree:$tree}' \
      | gh api --method POST "repos/$REPOSITORY/git/commits" --input - --jq .sha
  )"
  gh api --method POST "repos/$REPOSITORY/git/refs" \
    -f ref=refs/heads/gh-pages \
    -f sha="$COMMIT_SHA" >/dev/null
fi

if [[ "$PAGES_EXISTS" -eq 0 ]]; then
  gh api --method POST "repos/$REPOSITORY/pages" \
    -f build_type=legacy \
    -f 'source[branch]=gh-pages' \
    -f 'source[path]=/' >/dev/null
fi

echo "Published: https://hemsoft.github.io/codexbar-mac/appcast.xml"
