# Changelog

All notable changes to CodexBar for Mac are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

### Added

- Xcode project `CodexBarMac` with a `MenuBarExtra` menu bar shell (no Dock icon) and empty popover window.
- Core provider usage models ported from `codexbar-ios` (`ProviderID`, `UsageSeverity`, `UsageBar`, `ProviderUsageResult`, `ProviderAccountConfiguration`, `AutoRefreshInterval`, `AppAppearance`).
- Provider abstraction with `UsageRefreshService`, `ProviderConfigurationStore`, and `DemoUsageProvider` for concurrent refresh and demo data.

### Developer Experience

- `run.sh` script to build and launch the app from the command line.
- `AGENTS.md` and `README.md` document build and run instructions.
