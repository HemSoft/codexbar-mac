# CodexBar Mac Agent Notes

## What This Is

Native macOS menu bar app (Swift / SwiftUI, `MenuBarExtra`) showing AI provider
usage limits. Ports provider logic from the iOS app; the Windows app is a
secondary reference for local-credential-based fetching.

Sibling repos checked out locally:

```text
/Users/home/github/hemsoft/codexbar        # Windows (C# / WPF) — local CLI credential fetch reference
/Users/home/github/hemsoft/codexbar-ios    # iOS (SwiftUI) — primary source for models, parsers, providers
```

## Working Rules

- Work is sequenced in GitHub Issues. Pick up the lowest-numbered open V1
  issue unless directed otherwise, and link the issue in the PR.
- When porting from `codexbar-ios`, port behavior deliberately — do not blind-copy
  files. iOS uses browser-session auth for several providers; on the Mac prefer
  reading local CLI credentials (Codex CLI `~/.codex/auth.json`, GitHub CLI,
  Claude Code credentials) the way the Windows app does, with browser/API-key
  auth as fallback.
- Keychain access and credential files must never be logged or committed.
  Redact tokens in test fixtures.

## Changelog

`CHANGELOG.md` is the source of truth for release history, same discipline as
codexbar-ios: update the `Unreleased` section in the same branch/PR as every
user-visible change, describe user-observable behavior, and keep developer
experience changes under a separate `Developer Experience` heading.

## Build & Run

(To be filled in by the project scaffolding issue — Xcode project, scheme, and
run script land there.)
