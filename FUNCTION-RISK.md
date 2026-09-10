# Function coverage and risk

The required `Build and Test` CI job collects coverage and runs
`scripts/function-risk/measure.py`. A collection error or failed baseline
comparison fails that existing status check. The job publishes the compact
`function-risk-mac-<run-attempt>` artifact after a successful or failed
measurement. The attempt suffix prevents a rerun from colliding with the
original artifact. It contains raw xccov coverage, SwiftLint output, parsed
declarations, the policy, the reviewed baseline, the test summary, and JSON and
Markdown reports. The artifact remains available for 14 days.

If Xcode tests fail before measurement, CI preserves the full xcresult instead.
It does not attempt a strict upload for a measurement directory that was never
created. Collection failures write `failure.txt`, so a failed gate still has a
useful artifact.

## Measurement contract

Xcode 26.6 build 17F113 supplies the compiler, SwiftSyntax parser, and xccov.
CI downloads SwiftLint 0.65.1 from its official GitHub release and checks the
portable archive against the SHA-256 value in `policy.json` before running it.
The measurement command also checks both tool versions. Python 3 uses only the
standard library. A tool version change requires a reviewed policy and baseline
update.

The score is:

```text
CRAP = CC^2 * (1 - coverage)^3 + CC
```

Coverage is `coveredLines / executableLines` for each xccov function. Xccov
reports executable-line coverage, not branch coverage. A covered line cannot
prove that tests exercised every outcome of a condition on that line.

`CC` is SwiftLint's decision count, which starts at zero. This differs from the
conventional McCabe count that starts at one. SwiftLint counts decisions in
functions and initializers. The separate measurement configuration uses a
negative warning threshold so it also reports declarations with no decisions.
It does not replace any repository style policy.

The SwiftSyntax helper parses every Swift file under `CodexBarMac`. The policy
then compares that inventory with the `CodexBarMac` target's PBX Sources phase.
A source file missing from either side fails collection. Declaration identities
combine the source path, type and function scope, and syntax tokens. Formatting
and line shifts do not change an identity. Duplicate declaration, coverage
target, or complexity identities fail instead of silently choosing one.

The tool joins each declaration's header span to one xccov function and the
exact SwiftLint line and column. Missing and ambiguous joins remain unmatched.
The JSON report publishes every declaration's identity, source path, complexity,
covered and executable lines, coverage fraction, exact and displayed CRAP score,
source hash, status, and reason where applicable.

## Gate and review queue

- A new production declaration with a score above 30 fails.
- A baseline high-risk declaration fails if its score increases above its
  reviewed ceiling. A decrease is allowed and remains visible until a reviewer
  removes the stale ceiling.
- Scores from 15 through 30 form the review queue. Existing scores above 30 stay
  in the same Markdown table.
- Exact rational arithmetic decides pass or fail. Rounding applies only to the
  displayed report.
- Malformed counts, missing targets, empty target coverage, missing complexity,
  source inventory drift, duplicate identities, and unexplained joins fail.
- A removed high-risk declaration requires a baseline edit. CI never regenerates
  the baseline.

Accessors, stored-property initialization, standalone closures, deinitializers,
and synthesized symbols do not have an independent SwiftLint function or
initializer score. Xccov rows for the explicitly recognized forms remain in
`excluded_coverage` with a bounded reason. This includes preview closures and
the `deinit` and `__deallocating_deinit` symbol variants. Any other unjoined
production xccov declaration fails the gate instead of becoming a generic
exclusion. Generated or external source also stays visible in the report.
Platform-inactive function bodies are parsed but cannot receive xccov counters;
they require an individual unmatched baseline entry with a reason, exact source
hash, and measured complexity. The initial Mac baseline has no unmatched or
policy-excluded production declaration. None of these categories is treated as
covered, and there is no whole-app percentage target.

## Reproduce

Run from the repository root with Xcode 26.6 selected. Use a fresh result path
because Xcode refuses to overwrite an xcresult.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
mkdir -p DerivedData
risk_run="$(mktemp -d "$PWD/DerivedData/function-risk.XXXXXX")"
export FUNCTION_RISK_SWIFTLINT
FUNCTION_RISK_SWIFTLINT="$(./scripts/function-risk/install-swiftlint.sh "$risk_run/tools")"
xcodebuild -project CodexBarMac.xcodeproj -scheme CodexBarMac \
  -destination 'platform=macOS' -configuration Debug \
  -enableCodeCoverage YES \
  -resultBundlePath "$risk_run/CodexBarMacTests.xcresult" \
  CODE_SIGN_IDENTITY='-' CODE_SIGNING_REQUIRED=NO test
python3 scripts/function-risk/measure.py \
  --result "$risk_run/CodexBarMacTests.xcresult" \
  --output "$risk_run/function-risk-mac"
python3 -m unittest discover -s scripts/tests -p 'test_function_risk.py' -v
```

Inspect the raw function coverage with:

```sh
xcrun xccov view --report --json "$risk_run/CodexBarMacTests.xcresult"
```

The failure fixtures use temporary source and evidence. Their six-decision
uncovered function scores 42 and fails as a new risk, then full coverage lowers
the score to 6 and passes. Other fixtures cover a baseline increase smaller
than display precision, malformed counts, missing and ambiguous coverage,
duplicate identities, both kinds of source inventory drift, malformed xccov
aggregate counts, stale baseline entries, source-hash invalidation, recognized
deinitializers, and unknown production xccov declarations. They leave no broken
production source.

## Initial baseline

Issue [#193](https://github.com/HemSoft/codexbar-mac/issues/193) audited source
revision `c9a55815a5772da92ecbe117fb7f91d36dfda78e` with Xcode 26.6 build
17F113 on September 9, 2026. The local run covered 13,891 of 22,135
`CodexBarMac.app` executable lines, or 62.76%. The first `macos-26` CI run
covered 13,958 of 22,135 lines, or 63.06%. Both runs had 451 passing tests and
no failures or skips.

The function inventory has 841 scored declarations and no unmatched production
declaration. The full report retains 1,443 unscored xccov entries, including
test files, property accessors, initialization expressions, closures, and
synthesized symbols. The reviewed baseline records these six scores above 30
across the local and CI environments:

| CRAP | CC | Covered / executable | Declaration |
| ---: | ---: | ---: | --- |
| 72.0000 | 8 | 0 / 42 | `LaunchAtLoginManager.refreshFromSystem()` |
| 72.0000 | 8 | 0 / 54 | `ProviderSettingsView.saveOpenCodeCredential()` |
| 56.0000 | 7 | 0 / 28 | `SettingsView.syncUsageAlertAuthorizationState()` |
| 47.6413 | 25 | 91 / 136 | `ProviderConfigurationStore.applyLocalCredentialDiscoveries(_:)` |
| 34.3136 | 8 | 10 / 39 | `LaunchAtLoginManager.init(defaults:)` on the `macos-26` CI runner |
| 31.9746 | 10 | 23 / 58 | `CodexUsageProvider.fetchUsage(...)` |

These are ceilings, not exemptions from review. A change to one of these
functions must stay at or below its recorded score. A baseline increase is not
an acceptable substitute for tests or a smaller function.

The follow-up boundary is tied to the next behavior change in each area.
Launch-at-login changes must first add an injectable `SMAppService` adapter.
OpenCode credential-save changes must first extract the private SwiftUI workflow
behind a testable service. Notification authorization changes must first add an
injectable authorization adapter. Credential discovery and Codex fallback
changes must add the missing state and fallback cases. Once a score reaches 30
or lower, remove its high-risk entry in the same reviewed PR.
