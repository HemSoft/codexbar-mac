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

From the repo root:

```sh
./run.sh
```

Build only:

```sh
xcodebuild -project CodexBarMac.xcodeproj -scheme CodexBarMac build
```

Run unit tests (same command used by CI):

```sh
./test.sh
```

Open the project in Xcode:

```sh
open CodexBarMac.xcodeproj
```

The app is a menu bar agent (`LSUIElement`); it does not appear in the Dock.
Look for the chart.bar.fill SF Symbol in the menu bar after launch.

## Signing keychain (Developer ID)

Use the dedicated CodexBar signing keychain for release signing — the same
`codexbar-dev.keychain-db` workflow as `codexbar-ios`, adapted for **Developer
ID Application** distribution (not Apple Development / App Store):

```text
~/Library/Keychains/codexbar-dev.keychain-db
~/Library/Application Support/CodexBar/signing-keychain-password   # mode 600
```

Team ID: `W2A23PX5BP`.

- Unlock / verify without adding the keychain to the global search list:

  ```sh
  ./scripts/unlock-codexbar-keychain.sh
  ```

- Run signing commands through the temporary-search-list wrapper:

  ```sh
  ./scripts/with-codexbar-keychain.sh security find-identity -v -p codesigning
  ```

- Keep `codexbar-dev.keychain-db` **out** of the normal keychain search list
  (it locks on sleep; otherwise unrelated services prompt for its password).
- Never commit the password file, `.p12` exports, or notary API keys.
- Reset helper (interactive, hidden password dialogs): `./scripts/reset-codexbar-keychain.sh`

A valid **Developer ID Application** identity for team `W2A23PX5BP` must exist
in the dedicated keychain before notarized releases. Generate a CSR with
`./scripts/create-developer-id-csr.sh`, create the certificate in the Apple
Developer portal, import the `.cer` into `codexbar-dev.keychain-db`, then verify
with `find-identity`.

## Release & notarization

V1 ships as a notarized `.zip` of `CodexBarMac.app` via GitHub Releases.
Automatic in-app updates (Sparkle) and Homebrew cask packaging are **post-V1**;
users update by downloading the latest GitHub Release until then.

Prerequisites on the release machine:

1. Developer ID Application certificate in `codexbar-dev.keychain-db` (above).
2. `notarytool` credentials profile named `codexbar-notary` (override with
   `CODEXBAR_NOTARY_PROFILE`):

   ```sh
   xcrun notarytool store-credentials codexbar-notary --apple-id <id> --team-id W2A23PX5BP
   ```

Release flow (from a clean `main` after cutting product work):

```sh
# Verify signing + notary prerequisites without building
./scripts/release.sh --dry-run

# Build, Developer ID–sign, notarize, staple, and zip → dist/CodexBarMac-1.0.zip
./scripts/release.sh --version 1.0

# Same, then publish GitHub Release v1.0 with changelog-derived notes
./scripts/release.sh --version 1.0 --publish
```

`scripts/cut-changelog.sh` extracts notes from `CHANGELOG.md`. Pass `--write` only
when intentionally cutting `Unreleased` into a dated `## 1.0 - YYYY-MM-DD`
section after a successful release (then commit the changelog cut).

Smoke-test the changelog cutter without signing:

```sh
./scripts/test-cut-changelog.sh
```

## Cursor Cloud specific instructions

Cursor Cloud agents run on a **Linux** VM. This project is a **macOS-only Xcode
app** and **cannot be built, run, or tested on the Cloud Agent VM**:

- Building requires **Xcode 16 / `xcodebuild`** (macOS-only). There is no
 `Package.swift`, so `swift build` is not an option either.
- Sources import macOS-only frameworks (`SwiftUI`, `AppKit`, `Combine`,
 `Security`, `ServiceManagement`, `Darwin`). Even the pure-logic parsers depend
 transitively on `SwiftUI` (e.g. `UsageBar.severity` → `UsageSeverity.tint` →
 `Color`), so no meaningful subset compiles with a Swift-on-Linux toolchain.
- The `CodexBarMacTests` XCTest bundle is host-based (`TEST_HOST`/`BUNDLE_LOADER`
 point at the built `.app`) and imports `Darwin`, so tests also require macOS.

On the Linux Cloud VM, only **static code review** of the Swift sources is
possible. To actually build/run/test (`./run.sh`, `xcodebuild ... build`,
`xcodebuild ... test`), use a **macOS 14+ host with Xcode 16+** as documented in
`README.md` and the Build & Run section above. There are no package-manager
dependencies to install (only Apple system frameworks), so no dependency setup
step is needed.
