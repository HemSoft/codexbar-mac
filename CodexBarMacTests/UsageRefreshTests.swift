import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class UsageRefreshTests: XCTestCase {
    deinit {}

    @MainActor
    func testUsageRefreshServiceMarksProviderFailureResultsIncomplete() async {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: configuration.displayName,
            subtitle: "Cursor rate limit reached. Try again later.",
            bars: [],
            isIncompleteRefresh: true,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let service = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .cursor, result: result)]
        )

        let refreshed = await service.refresh(configurations: [configuration])

        XCTAssertTrue(refreshed)
        XCTAssertEqual(service.incompleteRefreshAccountIDs, [configuration.id])
        XCTAssertTrue(service.successfulRefreshResults.isEmpty)
    }

    @MainActor
    func testUsageRefreshServiceMergesCachedOpenCodeComponentsForPartialFailures() async throws {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.accountLabel = "OpenCode ZEN 2"
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let refreshedAt = Date(timeIntervalSince1970: 1_700_000_100)
        let cachedBars = [
            UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 20, limit: 100),
        ]
        let cached = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen 2",
            subtitle: "Go usage and ZEN credit balance",
            bars: cachedBars,
            creditsRemaining: 12,
            cacheIdentity: "unchanged-account",
            cacheScope: "wrk_test",
            fetchedAt: cachedAt
        )
        let balanceOnly = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode ZEN 2",
            subtitle: "ZEN credit balance",
            bars: [],
            creditsRemaining: 9,
            usageMessages: ["Go usage unavailable: Temporary outage"],
            preservesCachedBarsOnIncompleteRefresh: true,
            cacheIdentity: "unchanged-account",
            cacheScope: "wrk_test",
            isIncompleteRefresh: true,
            fetchedAt: refreshedAt
        )
        let balanceOnlyService = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .openCodeZen, result: balanceOnly)],
            initialResults: [cached]
        )

        let balanceOnlyRefreshed = await balanceOnlyService.refresh(configurations: [configuration])
        XCTAssertTrue(balanceOnlyRefreshed)
        let mergedBalanceOnly = try XCTUnwrap(balanceOnlyService.results.first)
        XCTAssertEqual(mergedBalanceOnly.title, "OpenCode Go + Zen 2")
        XCTAssertEqual(mergedBalanceOnly.bars, cachedBars)
        XCTAssertEqual(mergedBalanceOnly.creditsRemaining, 9)
        XCTAssertEqual(mergedBalanceOnly.usageMessages, balanceOnly.usageMessages)
        XCTAssertEqual(mergedBalanceOnly.fetchedAt, refreshedAt)

        let cachedBalanceOnly = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode ZEN 2",
            subtitle: "ZEN credit balance",
            bars: [],
            creditsRemaining: 12,
            cacheIdentity: "unchanged-account",
            cacheScope: "wrk_test",
            fetchedAt: cachedAt
        )
        let preGoService = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .openCodeZen, result: balanceOnly)],
            initialResults: [cachedBalanceOnly]
        )

        let preGoRefreshed = await preGoService.refresh(configurations: [configuration])
        XCTAssertTrue(preGoRefreshed)
        let freshBalanceOnly = try XCTUnwrap(preGoService.results.first)
        XCTAssertEqual(freshBalanceOnly.title, "OpenCode ZEN 2")
        XCTAssertTrue(freshBalanceOnly.bars.isEmpty)
        XCTAssertEqual(freshBalanceOnly.creditsRemaining, 9)
        XCTAssertEqual(freshBalanceOnly.subtitle, "ZEN credit balance")

        let freshBars = [
            UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 35, limit: 100),
        ]
        let goOnly = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go 2",
            subtitle: "OpenCode Go usage",
            bars: freshBars,
            usageMessages: ["ZEN balance unavailable: Temporary outage"],
            preservesCachedCreditsOnIncompleteRefresh: true,
            cacheIdentity: "unchanged-account",
            cacheScope: "wrk_test",
            isIncompleteRefresh: true,
            fetchedAt: refreshedAt
        )
        let goOnlyService = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .openCodeZen, result: goOnly)],
            initialResults: [cached]
        )

        let goOnlyRefreshed = await goOnlyService.refresh(configurations: [configuration])
        XCTAssertTrue(goOnlyRefreshed)
        let mergedGoOnly = try XCTUnwrap(goOnlyService.results.first)
        XCTAssertEqual(mergedGoOnly.title, "OpenCode Go + Zen 2")
        XCTAssertEqual(mergedGoOnly.bars, freshBars)
        XCTAssertEqual(mergedGoOnly.creditsRemaining, 12)
        XCTAssertEqual(mergedGoOnly.usageMessages, goOnly.usageMessages)
        XCTAssertEqual(mergedGoOnly.fetchedAt, refreshedAt)
    }

    @MainActor
    func testUsageRefreshServiceRetainsCachedOpenCodeTitleAfterTotalFailure() async throws {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.accountLabel = "OpenCode ZEN 2"
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cached = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen 2",
            subtitle: "Go usage and ZEN credit balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 20, limit: 100)],
            creditsRemaining: 12,
            cacheIdentity: "unchanged-account",
            cacheScope: "wrk_test",
            fetchedAt: cachedAt
        )
        let failure = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode ZEN 2",
            subtitle: "Temporary dashboard outage",
            bars: [],
            preservesCachedBarsOnIncompleteRefresh: true,
            preservesCachedCreditsOnIncompleteRefresh: true,
            cacheIdentity: "unchanged-account",
            cacheScope: "wrk_test",
            isIncompleteRefresh: true,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let service = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .openCodeZen, result: failure)],
            initialResults: [cached]
        )

        let refreshed = await service.refresh(configurations: [configuration])
        XCTAssertTrue(refreshed)
        let preserved = try XCTUnwrap(service.results.first)
        XCTAssertEqual(preserved.title, "OpenCode Go + Zen 2")
        XCTAssertEqual(preserved.bars, cached.bars)
        XCTAssertEqual(preserved.creditsRemaining, cached.creditsRemaining)
        XCTAssertEqual(preserved.subtitle, "Temporary dashboard outage. Showing last known data.")
        XCTAssertEqual(preserved.fetchedAt, cachedAt)
        XCTAssertTrue(preserved.isIncompleteRefresh)
    }

    @MainActor
    func testUsageRefreshServiceRejectsCachedOpenCodeComponentsAfterIdentityChanges() async throws {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_new"
        let cached = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen",
            subtitle: "Old account data",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 20, limit: 100)],
            creditsRemaining: 12,
            cacheIdentity: "old-credential",
            cacheScope: "wrk_old",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let changedWorkspace = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode ZEN",
            subtitle: "ZEN credit balance",
            bars: [],
            creditsRemaining: 9,
            preservesCachedBarsOnIncompleteRefresh: true,
            cacheIdentity: "new-credential",
            cacheScope: "wrk_new",
            isIncompleteRefresh: true,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let workspaceService = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .openCodeZen, result: changedWorkspace)],
            initialResults: [cached]
        )

        _ = await workspaceService.refresh(configuration: configuration)

        let workspaceResult = try XCTUnwrap(workspaceService.results.first)
        XCTAssertTrue(workspaceResult.bars.isEmpty)
        XCTAssertEqual(workspaceResult.creditsRemaining, 9)
        XCTAssertFalse(workspaceResult.subtitle.contains("last known data"))

        let sameWorkspaceCache = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen",
            subtitle: "Old credential data",
            bars: cached.bars,
            creditsRemaining: 12,
            cacheIdentity: "old-credential",
            cacheScope: "wrk_new",
            fetchedAt: cached.fetchedAt
        )
        let changedCredential = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go",
            subtitle: "OpenCode Go usage",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 40, limit: 100)],
            preservesCachedCreditsOnIncompleteRefresh: true,
            cacheIdentity: "new-credential",
            cacheScope: "wrk_new",
            isIncompleteRefresh: true,
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let credentialService = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .openCodeZen, result: changedCredential)],
            initialResults: [sameWorkspaceCache]
        )

        _ = await credentialService.refresh(configuration: configuration)

        let credentialResult = try XCTUnwrap(credentialService.results.first)
        XCTAssertEqual(credentialResult.bars, changedCredential.bars)
        XCTAssertNil(credentialResult.creditsRemaining)
        XCTAssertFalse(credentialResult.subtitle.contains("last known data"))
    }

    @MainActor
    func testOpenCodeCredentialReadFailureReusesOnlyMatchingWorkspaceCache() async throws {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_old"
        let cached = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen",
            subtitle: "Old workspace data",
            bars: [UsageBar(label: "Rolling", used: 25, limit: 100)],
            creditsRemaining: 12.5,
            cacheIdentity: "old-account-identity",
            cacheScope: "wrk_old",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let provider = OpenCodeZenUsageProvider(
            secretStore: MutableReadSecretStore(result: .failure(.invalidSecretData))
        )
        let service = UsageRefreshService(providers: [provider], initialResults: [cached])

        _ = await service.refresh(configuration: configuration)

        let preserved = try XCTUnwrap(service.results.first)
        XCTAssertEqual(preserved.bars, cached.bars)
        XCTAssertEqual(preserved.creditsRemaining, cached.creditsRemaining)
        XCTAssertEqual(preserved.cacheIdentity, cached.cacheIdentity)
        XCTAssertTrue(preserved.subtitle.contains("last known data"))

        configuration.openCodeWorkspaceId = "wrk_new"
        _ = await service.refresh(configuration: configuration)

        let failure = try XCTUnwrap(service.results.first)
        XCTAssertTrue(failure.bars.isEmpty)
        XCTAssertNil(failure.creditsRemaining)
        XCTAssertEqual(failure.cacheScope, "wrk_new")
        XCTAssertFalse(failure.subtitle.contains("last known data"))
    }

    @MainActor
    func testOpenCodeGenericFailureDoesNotUseWorkspaceOnlyCache() async throws {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        let cached = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen",
            subtitle: "Old credential data",
            bars: [UsageBar(label: "Rolling", used: 25, limit: 100)],
            creditsRemaining: 12.5,
            cacheIdentity: "old-account-identity",
            cacheScope: "wrk_test",
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let provider = SequencedUsageProvider(
            providerID: .openCodeZen,
            steps: [.failure("Request timed out")]
        )
        let service = UsageRefreshService(providers: [provider], initialResults: [cached])

        _ = await service.refresh(configuration: configuration)

        let failure = try XCTUnwrap(service.results.first)
        XCTAssertTrue(failure.bars.isEmpty)
        XCTAssertNil(failure.creditsRemaining)
        XCTAssertFalse(failure.subtitle.contains("last known data"))
    }

    func testUsageRefreshFetchRaceReturnsFastProviderResult() async {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let expected = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            fetchedAt: Date()
        )

        let result = await UsageRefreshService.fetchUsageWithTimeout(
            provider: StubUsageProvider(providerID: .codex, result: expected),
            configuration: configuration,
            timeout: .seconds(1)
        )

        XCTAssertEqual(result, expected)
    }

    func testUsageRefreshFetchRaceCancelsProviderWhenTimeoutWins() async throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let provider = BlockingUsageProvider(providerID: .codex)
        let refreshTask = Task {
            await UsageRefreshService.fetchUsageWithTimeout(
                provider: provider,
                configuration: configuration,
                timeout: .milliseconds(50)
            )
        }

        let didStart = await provider.waitUntilStarted()
        XCTAssertTrue(didStart)
        let result = await refreshTask.value
        let cancellationObserved = await provider.waitUntilCancellationObserved()

        XCTAssertEqual(result?.subtitle, "Refresh failed: Request timed out")
        XCTAssertTrue(cancellationObserved)
    }

    func testUsageRefreshFetchRaceReturnsNilAndCancelsProviderWithCaller() async {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let provider = BlockingUsageProvider(providerID: .codex)
        let refreshTask = Task {
            await UsageRefreshService.fetchUsageWithTimeout(
                provider: provider,
                configuration: configuration,
                timeout: .seconds(30)
            )
        }

        let didStart = await provider.waitUntilStarted()
        XCTAssertTrue(didStart)
        refreshTask.cancel()
        let result = await refreshTask.value
        let cancellationObserved = await provider.waitUntilCancellationObserved()

        XCTAssertNil(result)
        XCTAssertTrue(cancellationObserved)
    }

    @MainActor
    func testUsageRefreshServicePreservesLastKnownUsageAcrossFailureAndRecovery() async throws {
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let recoveredAt = Date(timeIntervalSince1970: 2_000_000_000)
        let metric = ProviderMonetaryMetric(
            kind: .spent,
            label: "Spent",
            minorUnits: 1_250,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let recoveredMetric = ProviderMonetaryMetric(
            kind: .spent,
            label: "Spent",
            minorUnits: 2_500,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let scenarios: [(cached: ProviderUsageResult, recovered: ProviderUsageResult)] = [
            (
                ProviderUsageResult(
                    accountID: "codex.bars",
                    providerID: .codex,
                    title: "Codex Bars",
                    subtitle: "Live usage",
                    bars: [UsageBar(label: "Weekly", used: 40, limit: 100)],
                    fetchedAt: cachedAt
                ),
                ProviderUsageResult(
                    accountID: "codex.bars",
                    providerID: .codex,
                    title: "Codex Bars",
                    subtitle: "Live usage",
                    bars: [UsageBar(label: "Weekly", used: 55, limit: 100)],
                    fetchedAt: recoveredAt
                )
            ),
            (
                ProviderUsageResult(
                    accountID: "openrouter.balance",
                    providerID: .openRouter,
                    title: "OpenRouter Balance",
                    subtitle: "Credit balance",
                    bars: [],
                    creditsRemaining: 12.50,
                    fetchedAt: cachedAt
                ),
                ProviderUsageResult(
                    accountID: "openrouter.balance",
                    providerID: .openRouter,
                    title: "OpenRouter Balance",
                    subtitle: "Credit balance",
                    bars: [],
                    creditsRemaining: 10,
                    fetchedAt: recoveredAt
                )
            ),
            (
                ProviderUsageResult(
                    accountID: "claude.metrics",
                    providerID: .claude,
                    title: "Claude Metrics",
                    subtitle: "Live usage",
                    bars: [],
                    monetaryMetrics: [metric],
                    fetchedAt: cachedAt
                ),
                ProviderUsageResult(
                    accountID: "claude.metrics",
                    providerID: .claude,
                    title: "Claude Metrics",
                    subtitle: "Live usage",
                    bars: [],
                    monetaryMetrics: [recoveredMetric],
                    fetchedAt: recoveredAt
                )
            ),
        ]

        for scenario in scenarios {
            let configuration = ProviderAccountConfiguration(
                id: scenario.cached.accountID,
                providerID: scenario.cached.providerID,
                accountLabel: scenario.cached.title,
                authMethod: .browserSession
            )
            let provider = SequencedUsageProvider(
                providerID: scenario.cached.providerID,
                steps: [
                    .failure("Temporary outage"),
                    .result(scenario.recovered),
                ]
            )
            let service = UsageRefreshService(
                providers: [provider],
                initialResults: [scenario.cached]
            )

            let failedRefreshCompleted = await service.refresh(configurations: [configuration])

            XCTAssertTrue(failedRefreshCompleted)
            let preserved = try XCTUnwrap(service.results.first)
            XCTAssertEqual(preserved.bars, scenario.cached.bars)
            XCTAssertEqual(preserved.creditsRemaining, scenario.cached.creditsRemaining)
            XCTAssertEqual(preserved.monetaryMetrics, scenario.cached.monetaryMetrics)
            XCTAssertEqual(preserved.fetchedAt, scenario.cached.fetchedAt)
            XCTAssertEqual(
                preserved.subtitle,
                "Refresh failed: Temporary outage. Showing last known data."
            )
            XCTAssertTrue(preserved.isIncompleteRefresh)
            XCTAssertEqual(service.incompleteRefreshAccountIDs, [configuration.id])
            XCTAssertTrue(
                service.successfulRefreshResults.isEmpty,
                "Incomplete preserved snapshots must not reach history or alert evaluation."
            )

            let recoveryRefreshCompleted = await service.refresh(configurations: [configuration])

            XCTAssertTrue(recoveryRefreshCompleted)
            XCTAssertEqual(service.results, [scenario.recovered])
            XCTAssertEqual(service.successfulRefreshResults, [scenario.recovered])
            XCTAssertTrue(service.incompleteRefreshAccountIDs.isEmpty)
        }
    }

    @MainActor
    func testSingleAccountFailurePreservesLastKnownUsageAndIncompleteState() async throws {
        let configuration = ProviderAccountConfiguration(
            id: "codex.single",
            providerID: .codex,
            accountLabel: "Codex Single",
            authMethod: .browserSession
        )
        let cached = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 40, limit: 100)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let provider = SequencedUsageProvider(
            providerID: .codex,
            steps: [.failure("Temporary outage")]
        )
        let service = UsageRefreshService(providers: [provider], initialResults: [cached])

        let returnedResult = await service.refresh(configuration: configuration)
        let failure = try XCTUnwrap(returnedResult)

        XCTAssertTrue(failure.isIncompleteRefresh)
        XCTAssertTrue(failure.bars.isEmpty)
        XCTAssertEqual(service.results.first?.bars, cached.bars)
        XCTAssertEqual(
            service.results.first?.subtitle,
            "Refresh failed: Temporary outage. Showing last known data."
        )
        XCTAssertEqual(service.incompleteRefreshAccountIDs, [configuration.id])
        XCTAssertTrue(service.successfulRefreshResults.isEmpty)
    }

    @MainActor
    func testStaleSingleAccountFailureDoesNotInvalidateNewerSuccessfulResult() async throws {
        let configuration = ProviderAccountConfiguration(
            id: "codex.single",
            providerID: .codex,
            accountLabel: "Codex Single",
            authMethod: .browserSession
        )
        let newerSuccess = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 40, limit: 100)],
            fetchedAt: .distantFuture
        )
        let provider = SequencedUsageProvider(
            providerID: .codex,
            steps: [.failure("Older overlapping failure")]
        )
        let service = UsageRefreshService(
            providers: [provider],
            initialResults: [newerSuccess]
        )

        let returnedResult = await service.refresh(configuration: configuration)
        let staleFailure = try XCTUnwrap(returnedResult)

        XCTAssertTrue(staleFailure.isIncompleteRefresh)
        XCTAssertEqual(service.results, [newerSuccess])
        XCTAssertEqual(service.successfulRefreshResults, [newerSuccess])
        XCTAssertTrue(service.incompleteRefreshAccountIDs.isEmpty)
    }

    @MainActor
    func testUsageRefreshServiceTracksSuccessfulResultsAndSkipsDisabledAccounts() async {
        let enabled = ProviderAccountConfiguration(
            providerID: .codex,
            isEnabled: true,
            accountLabel: "Codex Live",
            authMethod: .codexAuthJSON
        )
        let disabled = ProviderAccountConfiguration(
            providerID: .cursor,
            isEnabled: false,
            accountLabel: "Cursor Off",
            authMethod: .browserSession
        )

        let success = ProviderUsageResult(
            accountID: enabled.id,
            providerID: .codex,
            title: "Codex Live",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "5-hour", used: 10, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let ignored = ProviderUsageResult(
            accountID: disabled.id,
            providerID: .cursor,
            title: "Cursor Off",
            subtitle: "Should not refresh",
            bars: [],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let service = UsageRefreshService(
            providers: [
                StubUsageProvider(providerID: .codex, result: success),
                StubUsageProvider(providerID: .cursor, result: ignored),
            ]
        )

        let refreshed = await service.refresh(configurations: [enabled, disabled])

        XCTAssertTrue(refreshed)
        XCTAssertEqual(service.results.map(\.accountID), [enabled.id])
        XCTAssertEqual(service.successfulRefreshResults.map(\.accountID), [enabled.id])
        XCTAssertTrue(service.incompleteRefreshAccountIDs.isEmpty)
    }

}
