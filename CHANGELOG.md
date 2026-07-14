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

### Fixed

- GitHub Copilot CLI accounts prefer fresh GitHub CLI tokens over stale saved Keychain secrets.
- GitHub Copilot reset countdown falls back to date-only reset fields when UTC timestamps are absent.

### Developer Experience

- `CodexBarMacTests` target with parser and provider unit tests using redacted fixtures.

- `run.sh` script to build and launch the app from the command line.
- `AGENTS.md` and `README.md` document build and run instructions.
- `AGENTS.md` documents that Cursor Cloud (Linux) agents can only perform static review; build, run, and test require macOS with Xcode.
