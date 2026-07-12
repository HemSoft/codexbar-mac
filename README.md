# CodexBar 🎚️ for Mac

A native macOS menu bar app that keeps your AI provider usage limits visible. The Mac member of the CodexBar family:

- [codexbar](https://github.com/HemSoft/codexbar) — Windows (C# / WPF / .NET 9)
- [codexbar-ios](https://github.com/HemSoft/codexbar-ios) — iOS (SwiftUI)
- Inspired by [steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT) by Peter Steinberger

Built with Swift / SwiftUI using `MenuBarExtra` — native macOS, no Electron overhead.

## Status

🚧 **Early development.** The menu bar app shell builds and runs; provider logic is being ported from `codexbar-ios`. V1 work is sequenced in [GitHub Issues](https://github.com/HemSoft/codexbar-mac/issues). Because the app runs on the same machine as your CLI tools, it can read local credentials (Codex CLI, GitHub CLI) directly instead of requiring browser sign-in.

## Build & Run

Requires Xcode 16 or later on macOS 14+.

```sh
./run.sh
```

This builds `CodexBarMac` and launches it. The app lives in the menu bar only (no Dock icon). Click the chart.bar.fill icon to open the empty popover shell.

Build without launching:

```sh
xcodebuild -project CodexBarMac.xcodeproj -scheme CodexBarMac build
```

## Planned Providers (V1)

| Provider | Auth Method | What's Tracked |
|----------|-------------|----------------|
| **ChatGPT / Codex** | Codex CLI login (`~/.codex/auth.json`) | 5-hour + weekly usage limits |
| **Claude** | Claude Code OAuth credentials | Session + weekly limits, model-scoped limits |
| **GitHub Copilot** | GitHub CLI (`gh auth`) | Usage limits per account |
| **OpenRouter** | API key | Credits, usage across models |
| **Cursor** | Browser session | Usage limits |
| **OpenCode ZEN** | API key | Credits |

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
