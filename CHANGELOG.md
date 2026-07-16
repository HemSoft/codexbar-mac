# Changelog

All notable changes to CodexBar for Mac are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- Xcode project `CodexBarMac` with a `MenuBarExtra` menu bar shell (no Dock icon) and empty popover window.
- Core provider usage models ported from `codexbar-ios` (`ProviderID`, `UsageSeverity`, `UsageBar`, `ProviderUsageResult`, `ProviderAccountConfiguration`, `AutoRefreshInterval`, `AppAppearance`).
- Provider abstraction with `UsageRefreshService`, `ProviderConfigurationStore`, and `DemoUsageProvider` for concurrent refresh and demo data.
- Menu bar icon tinted by the most urgent usage severity, with a popover dashboard showing provider usage cards, manual refresh, and a settings stub.
- Right-click menu on the menu bar icon with Refresh, Settings, and Quit actions.
- Native Settings window for appearance, auto-refresh, launch at login, and per-provider account management with immediate dashboard updates.
- Keychain-backed API key storage and local CLI credential discovery for Codex (`~/.codex/auth.json`), GitHub CLI (`gh auth status`), and Claude Code (`~/.claude/.credentials.json`).
- Live ChatGPT / Codex usage fetching from local CLI credentials with proactive token refresh, 5-hour and weekly usage windows, and reset countdowns.
- Live Claude usage fetching from Claude Code OAuth credentials with session, weekly, OAuth-app weekly, and model-scoped limit bars.
- Live GitHub Copilot usage fetching from GitHub CLI credentials with premium and chat quota bars per account.
- Live OpenRouter credit balance fetching from Keychain-stored management API keys.
- Live Cursor plan usage fetching from Keychain-stored browser sessions or the local Cursor app auth file, with PKCE browser sign-in and session-expiry prompts.
- Live OpenCode ZEN credit balance fetching from Keychain-stored dashboard auth values and workspace IDs, with Windows settings JSON import support.
- Configurable usage alerts via macOS notifications with threshold crossing detection, honoring each provider's enabled/disabled setting, and warning/critical severity alerts.

### Fixed

- Cursor on-demand alerts now format spend amounts in dollars instead of raw cents.
- GitHub Copilot CLI accounts prefer fresh GitHub CLI tokens over stale saved Keychain secrets.
- GitHub Copilot reset countdown falls back to date-only reset fields when UTC timestamps are absent.
- GitHub Copilot usage-based billing accounts label premium quota bars as AI credits.
- GitHub Copilot falls back to the active GitHub CLI account when no stored CLI username is configured.
- GitHub Copilot omits token-based placeholder snapshots that do not include usable quota data.
- GitHub Copilot saved tokens take precedence over the active GitHub CLI account when no CLI username is bound.
- GitHub Copilot pooled quota exhaustion is shown when GitHub reports unlimited snapshots with no remaining quota.

### Developer Experience

- `CodexBarMacTests` target with parser and provider unit tests using redacted fixtures.
- GitHub Actions CI on `macos-15` runs `xcodebuild test` for pulls and pushes to `main` (check name: **Build and Test**).
- `./test.sh` runs the same local `xcodebuild test` flow used by CI.
- Additional Mac-specific coverage for `UsageRefreshService` success/disabled-account handling and GitHub CLI credential discovery parsing.
- `run.sh` script to build and launch the app from the command line.
- `AGENTS.md` and `README.md` document build and run instructions.
- `AGENTS.md` documents that Cursor Cloud (Linux) agents can only perform static review; build, run, and test require macOS with Xcode.
