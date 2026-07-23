# CodexBar 🎚️ for Mac

A native macOS menu bar app that keeps your AI provider usage limits visible. The Mac member of the CodexBar family:

- [codexbar](https://github.com/HemSoft/codexbar) — Windows (C# / WPF / .NET 9)
- [codexbar-ios](https://github.com/HemSoft/codexbar-ios) — iOS (SwiftUI)
- Inspired by [steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT) by Peter Steinberger

Built with Swift / SwiftUI using `MenuBarExtra` — native macOS, no Electron overhead.

## Status

🚧 **Pre-release development.** CodexBar Mac has an implemented menu bar dashboard for eight live V1 providers, with per-provider account settings, manual and automatic refresh, usage history, alerts, launch at login, and signed Sparkle updates. Because the app runs alongside your CLI tools, it prefers local credentials when available and offers browser sign-in or API-key configuration where appropriate.

## Build & Run

Requires Xcode 16 or later on macOS 14+.

```sh
./run.sh
```

This builds `CodexBarMac` and launches it. The app lives in the menu bar only (no Dock icon). Click the chart.bar.fill icon to open the provider usage dashboard.

Build without launching:

```sh
xcodebuild -project CodexBarMac.xcodeproj -scheme CodexBarMac build
```

Run the unit test suite:

```sh
./test.sh
```

GitHub Actions runs the same `xcodebuild test` flow on `macos-26` (Xcode 26.6) for pulls and pushes to `main`. The required check name is **Build and Test**.

## Download / Release

Notarized macOS builds are published as immutable GitHub Release ZIPs. Direct-download
builds use Sparkle for EdDSA-verified in-app updates from
`https://hemsoft.github.io/codexbar-mac/appcast.xml`. Use **Check for Updates…** in the
menu bar popover at any time; Sparkle asks on the second launch before enabling
automatic background checks.

The same versioned ZIP and SHA-256 generate the optional `codexbar-mac` Homebrew
cask. It is published through `HemSoft/homebrew-tap` by reviewed PR after that
tap repository is available.

Maintainers: see **Signing keychain** and **Release, updates & notarization** in [`AGENTS.md`](AGENTS.md).

## Live Providers (V1)

| Provider | Auth Method | What's Tracked |
|----------|-------------|----------------|
| **ChatGPT / Codex** | Codex CLI (`~/.codex/auth.json`) preferred; browser OAuth fallback stored in Keychain | 5-hour + weekly usage limits |
| **Claude** | Claude Code OAuth credentials from Keychain or `~/.claude/.credentials.json` preferred; browser OAuth fallback stored in Keychain | Session + weekly limits, model-scoped limits, and available spend data |
| **GitHub Copilot** | GitHub CLI (`gh auth status`) preferred; browser OAuth fallback stored in Keychain | Premium + chat quotas per account, with optional organization AI-credit billing |
| **OpenRouter** | Management API key stored in Keychain | Credit balance |
| **Cursor** | Local Cursor app auth file or browser sign-in stored in Keychain | Plan usage and on-demand spend |
| **OpenCode ZEN** | Workspace ID + dashboard auth value stored in Keychain; optional Windows settings import | Credit balance |
| **Moonshot (Kimi)** | `platform.kimi.ai` API key stored in Keychain | Credit balance |
| **Gemini** | Gemini CLI OAuth credentials (`~/.gemini/oauth_creds.json`) | Pro + Flash quotas |

## Planned Work

Remaining pre-release polish and release work is tracked in [GitHub Issues](https://github.com/HemSoft/codexbar-mac/issues).

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 16 or later (to build from source)

## Reference Repos

The sibling implementations are checked out beside this repo:

```text
/Users/home/github/hemsoft/codexbar        # Windows — provider fetch logic reference
/Users/home/github/hemsoft/codexbar-ios    # iOS — Swift models, parsers, and providers to port
```

The Mac app ports provider behavior from `codexbar-ios` deliberately rather than sharing project structure directly.

## License

MIT
