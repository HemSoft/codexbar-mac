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
- Browser OAuth sign-in for ChatGPT / Codex and Claude with PKCE loopback callbacks and Keychain token storage, used as a fallback while local CLI credentials remain preferred.
- Live Claude usage fetching from Claude Code OAuth credentials with session, weekly, OAuth-app weekly, and model-scoped limit bars.
- Claude monetary rows for usage credits spent, monthly spend limit, remaining headroom, and prepaid balance when OAuth usage includes `spend` (preferred) or legacy `extra_usage`.
- Live GitHub Copilot usage fetching from preferred GitHub CLI credentials or Keychain-backed browser OAuth with automatic token renewal, with premium and chat quota bars per account and organization AI-credit billing (optional enterprise path and allotment override) from Settings.
- Live OpenRouter credit balance fetching from Keychain-stored management API keys.
- Live Cursor plan usage fetching from Keychain-stored browser sessions or the local Cursor app auth file, with PKCE browser sign-in and session-expiry prompts.
- Live OpenCode ZEN credit balance fetching from Keychain-stored dashboard auth values and workspace IDs, with Windows settings JSON import support.
- OpenCode Go rolling 5-hour, weekly, and monthly subscription usage alongside independently refreshed ZEN balances.
- Live Moonshot (Kimi) credit balance fetching from Keychain-stored API keys via `api.moonshot.ai`.
- Live Gemini Pro and Flash quota fetching from Gemini CLI OAuth credentials in `~/.gemini/oauth_creds.json`, with automatic token refresh and reset countdowns.
- Configurable usage alerts via macOS notifications with threshold crossing detection, honoring each provider's enabled/disabled setting, and warning/critical severity alerts.
- Account-scoped active alert details on provider cards, including the triggering condition, configured threshold, and reset context when available.
- Local on-device usage history with compact sparklines on provider popover cards after successful refreshes.
- Expanded on-device history sheets with interactive charts, metric summaries, series selection, and recent samples.
- Account groups in Settings, including create, rename, delete, and per-account group assignment.
- Manual or smart dashboard ordering, with smart mode prioritizing urgent usage, low balances, and projected limit exhaustion.
- Per-account **Show History** settings hide compact sparklines without deleting saved usage samples.
- Secure Sparkle 2 in-app updates for direct-download builds, with a visible **Check for Updates…** action, second-launch consent for automatic checks, and EdDSA verification of archives, feeds, and release notes.
- Resizable menu-bar and standalone dashboard presentations with persisted dashboard text-size controls and standard macOS zoom shortcuts.

### Changed

- The menu bar popover uses a narrower, content-friendlier frame, tighter card spacing, and a single compact header for refresh, settings, and quit actions.
- The README provider table now documents OpenCode Go subscription usage alongside the independent ZEN credit balance.

### Fixed

- OpenCode last-known usage now stays scoped to the workspace and dashboard
  credential that produced it instead of carrying bars or balances across account changes.
- ChatGPT browser sign-in now rejects duplicate or unverifiable identities across
  saved Codex accounts without changing existing account credentials or metadata.
- Additional Codex and Claude browser accounts now use their account-specific
  saved credentials while the default account keeps preferring local CLI sign-in.
- Claude usage now fills missing provider spend and limit values from compatible
  legacy data without replacing balances or deriving mismatched headroom.
- Claude usage responses now preserve valid session, weekly, and monetary data
  when neighboring optional sections or structured-limit fields are malformed.
- Healthy usage history now remains intact while damaged account data awaits
  explicit recovery, including across relaunches, then resumes cleanup against
  the replacement account list.
- Cursor history now follows Total usage by default, keeps Total, Auto, API, and On-demand as distinct
  series, and continues to read previously saved label-only snapshots.
- OpenCode ZEN Settings saves and bootstrap imports now keep account metadata
  and dashboard credentials consistent when Keychain or account persistence fails.
- Failed credential saves and removals now preserve retryable Settings state,
  show the storage error, and refresh only after Keychain changes succeed.
- Usage refresh timeouts and cancellation now safely coordinate in-flight tasks,
  preventing refresh races while still cancelling work that loses the race.
- Browser sign-in now keeps Codex, Claude, and GitHub Copilot credentials aligned
  with their saved authentication and account metadata when replacement storage fails.
- Damaged saved group data now preserves account assignments until the user
  explicitly replaces the unreadable groups in Settings.
- Codex cards now omit redundant usage-threshold alert summaries while
  preserving notifications, severity indicators, and other alert types.
- Damaged saved usage history now remains intact until the user explicitly resets
  it, with recording resuming normally after recovery.
- Damaged saved account lists now remain intact with their Keychain credentials
  until the user explicitly replaces the unreadable list in Settings.
- Usage history save failures now restore the last persisted snapshots, show a non-sensitive error in the popover, and clear the error after a successful save.
- Usage history now preserves dense recent samples while retaining deterministic coverage across the configured 30-day window at every supported refresh interval.
- Monetary history now keeps balances and remaining spend headroom in separate trend series instead of combining them when the primary metric changes.
- Corrupted Keychain credentials now appear as actionable Settings errors instead of being reported as missing credentials.
- Transient provider failures now keep the last successful usage bars, balances, and monetary metrics visible while clearly marking the snapshot as stale.
- Codex and Claude credential refreshes now report a persistence failure when owner-only file permissions cannot be restored.
- Reset Accounts now preserves the first Keychain deletion error across a partial reset, keeps failed accounts available for retry, and refreshes usage only when an account was removed.
- Gemini token refresh now preserves newer access, refresh, and ID tokens when
  the Gemini CLI updates its credential file during an in-flight refresh.
- Cursor browser sign-in failures now omit raw token-endpoint responses and
  untrusted error descriptions while retaining the HTTP status and safe OAuth
  error codes needed to understand failures.
- OpenCode ZEN bootstrap credentials are restricted to the current user before import and removed after every detected import attempt, including invalid payloads and storage failures.
- Browser sign-in callbacks now handle HTTP requests split across network packets and reject incomplete or oversized requests cleanly.
- Claude usage refreshes no longer send inference requests when OAuth usage is unavailable or incomplete, while preserving cached rate-limit bars alongside partial usage data.
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

- The status-item right-click event bridge now makes its synchronous main-actor
  isolation explicit and has focused event-routing coverage.
- CI now pins `actions/checkout` v7.0.1 to its reviewed full commit SHA while retaining credential hardening.
- Credential replacement test doubles now synchronize injected failures, saved-secret
  observations, and credential storage so detached availability checks cannot race them.
- `CodexBarMacTests` target with parser and provider unit tests using redacted fixtures.
- GitHub Actions CI on `macos-26` (Xcode 26.6) runs `xcodebuild test` for pulls and pushes to `main` (check name: **Build and Test**).
- `./test.sh` runs the same local `xcodebuild test` flow used by CI.
- Additional Mac-specific coverage for `UsageRefreshService` success/disabled-account handling and GitHub CLI credential discovery parsing.
- Developer ID release tooling: dedicated `codexbar-dev` keychain helpers, `scripts/release.sh` (sign / notarize / staple / zip / optional GitHub Release), `scripts/cut-changelog.sh`, and release docs in `AGENTS.md`.
- Release publication now preserves immutable GitHub Release assets, generates and publishes the signed Sparkle appcast through GitHub Pages, and emits a deterministic Homebrew cask for a reviewed `HemSoft/homebrew-tap` update.
- Release artifact smoke tests cover signed-appcast validation, exact versioned URLs, deterministic cask output, missing prerequisites, and publication dry runs.
- App Release signing team set to `W2A23PX5BP` with hardened-runtime entitlements for network client access (Debug remains team-agnostic for local builds).
- `run.sh` script to build and launch the app from the command line.
- `run.sh` now falls back from Command Line Tools to an installed Xcode, with script-level regression coverage that does not launch the app.
- `AGENTS.md` and `README.md` document build and run instructions.
- `AGENTS.md` documents that Cursor Cloud (Linux) agents can only perform static review; build, run, and test require macOS with Xcode.
