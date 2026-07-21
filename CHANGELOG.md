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
- Live Moonshot (Kimi) credit balance fetching from Keychain-stored API keys via `api.moonshot.ai`.
- Live Gemini Pro and Flash quota fetching from Gemini CLI OAuth credentials in `~/.gemini/oauth_creds.json`, with automatic token refresh and reset countdowns.
- Configurable usage alerts via macOS notifications with threshold crossing detection, honoring each provider's enabled/disabled setting, and warning/critical severity alerts.
- Local on-device usage history with compact sparklines on provider popover cards after successful refreshes.

### Fixed

- Gemini Code Assist project IDs are accepted when returned as objects (`id` / `projectId`) as well as strings, and Cloud Resource Manager is queried when no project is otherwise available so menu-bar launches without shell env can still fetch quota.
- Gemini CLI auth gating treats ADC, Cloud Shell, gateway, and other non-OAuth modes as unsupported, and prefers Resource Manager projects labeled for generative language when choosing a fallback quota project.
- Gemini credential and settings paths honor `GEMINI_CLI_HOME` the same way Gemini CLI does (`$GEMINI_CLI_HOME/.gemini/...`).
- Gemini usage fetching derives CLI settings from the same directory as the OAuth credentials path, so custom/test paths are not gated by the machine-wide `~/.gemini/settings.json`.
- Gemini quota project resolution prefers `GOOGLE_CLOUD_PROJECT` / `GOOGLE_CLOUD_PROJECT_ID` over `GOOGLE_CLOUD_QUOTA_PROJECT`, and pages Cloud Resource Manager results until a Code Assist project is found.
- Gemini Resource Manager fallback only uses labeled or `gen-lang-client` projects; unrelated GCP projects no longer become the quota project.
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
- GitHub Actions CI on `macos-26` (Xcode 26.6) runs `xcodebuild test` for pulls and pushes to `main` (check name: **Build and Test**).
- `./test.sh` runs the same local `xcodebuild test` flow used by CI.
- Additional Mac-specific coverage for `UsageRefreshService` success/disabled-account handling and GitHub CLI credential discovery parsing.
- Developer ID release tooling: dedicated `codexbar-dev` keychain helpers, `scripts/release.sh` (sign / notarize / staple / zip / optional GitHub Release), `scripts/cut-changelog.sh`, and release docs in `AGENTS.md`.
- App Release signing team set to `W2A23PX5BP` with hardened-runtime entitlements for network client access (Debug remains team-agnostic for local builds).
- `run.sh` script to build and launch the app from the command line.
- `AGENTS.md` and `README.md` document build and run instructions.
- `AGENTS.md` documents that Cursor Cloud (Linux) agents can only perform static review; build, run, and test require macOS with Xcode.
