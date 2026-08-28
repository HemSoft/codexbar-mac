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

    @MainActor
    func testRefreshInputsDistinguishRoutingChangesFromPresentationChanges() {
        let original = ProviderAccountConfiguration(
            id: "copilot.refresh-inputs",
            providerID: .copilot,
            accountLabel: "Original",
            groupID: "personal",
            showsHistory: true,
            authMethod: .oauth,
            oauthClientID: "client-one",
            copilotAccountScope: .organization,
            githubOrganization: "org-one",
            githubEnterprise: "enterprise-one",
            githubCLIUsername: "user-one",
            copilotTotalAllotment: 1_000,
            openCodeWorkspaceId: "workspace-one"
        )
        let service = UsageRefreshService(providers: [])

        var presentationOnly = original
        presentationOnly.accountLabel = "Renamed"
        presentationOnly.groupID = "work"
        presentationOnly.showsHistory = false
        XCTAssertTrue(service.hasSameRefreshInputs(original, presentationOnly))

        var inputChanges: [ProviderAccountConfiguration] = []
        inputChanges.append(ProviderAccountConfiguration(
            id: original.id,
            providerID: .codex,
            authMethod: original.authMethod
        ))
        var authMethod = original
        authMethod.authMethod = .browserSession
        inputChanges.append(authMethod)
        var oauthClientID = original
        oauthClientID.oauthClientID = "client-two"
        inputChanges.append(oauthClientID)
        var scope = original
        scope.copilotAccountScope = .personal
        inputChanges.append(scope)
        var organization = original
        organization.githubOrganization = "org-two"
        inputChanges.append(organization)
        var enterprise = original
        enterprise.githubEnterprise = "enterprise-two"
        inputChanges.append(enterprise)
        var cliUsername = original
        cliUsername.githubCLIUsername = "user-two"
        inputChanges.append(cliUsername)
        var allotment = original
        allotment.copilotTotalAllotment = 2_000
        inputChanges.append(allotment)
        var workspace = original
        workspace.openCodeWorkspaceId = "workspace-two"
        inputChanges.append(workspace)
        var grokBotVisibility = original
        grokBotVisibility.showsCursorGrokBotWeekly = false
        inputChanges.append(grokBotVisibility)

        for changed in inputChanges {
            XCTAssertFalse(service.hasSameRefreshInputs(original, changed))
        }
    }

    @MainActor
    func testGatedBatchAndSingleCompletionsRespectAccountInvalidation() async throws {
        for path in RefreshTestPath.allCases {
            for providerOutcome in RefreshTestProviderOutcome.allCases {
                for mutation in RefreshTestMutation.allCases {
                    let assertionLabel = "\(path.rawValue)-\(providerOutcome.rawValue)-\(mutation.rawValue)"
                    let configuration = ProviderAccountConfiguration(
                        id: "codex.\(path.rawValue).\(providerOutcome.rawValue).\(mutation.rawValue)",
                        providerID: .codex,
                        accountLabel: "Original Codex",
                        groupID: "personal",
                        showsHistory: true,
                        authMethod: .browserSession,
                        oauthClientID: "client-one"
                    )
                    let cached = ProviderUsageResult(
                        accountID: configuration.id,
                        providerID: .codex,
                        title: configuration.displayName,
                        subtitle: "Cached usage",
                        bars: [UsageBar(label: "Weekly", used: 10, limit: 100)],
                        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
                    )
                    let fresh = ProviderUsageResult(
                        accountID: configuration.id,
                        providerID: .codex,
                        title: configuration.displayName,
                        subtitle: "Fresh usage",
                        bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
                        fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
                    )
                    let outcome: GatedUsageProvider.Outcome = switch providerOutcome {
                    case .success:
                        .result(fresh)
                    case .failure:
                        .failure("Suspended failure")
                    }
                    let provider = GatedUsageProvider(providerID: .codex, outcome: outcome)
                    let service = UsageRefreshService(
                        providers: [provider],
                        initialResults: [cached]
                    )
                    service.updateCurrentConfigurations([configuration])
                    XCTAssertEqual(service.results, [cached], assertionLabel)

                    let refresh = Task { @MainActor in
                        switch path {
                        case .batch:
                            return RefreshTestInvocation.batch(
                                await service.refresh(configurations: [configuration])
                            )
                        case .single:
                            return RefreshTestInvocation.single(
                                await service.refresh(configuration: configuration)
                            )
                        }
                    }

                    let didStart = await provider.waitUntilStarted()
                    XCTAssertTrue(didStart, assertionLabel)
                    switch mutation {
                    case .remove:
                        service.updateCurrentConfigurations([])
                    case .disable:
                        var changed = configuration
                        changed.isEnabled = false
                        service.updateCurrentConfigurations([changed])
                    case .credential:
                        service.invalidateCredential(forAccountID: configuration.id)
                    case .refreshInput:
                        var changed = configuration
                        changed.oauthClientID = "client-two"
                        service.updateCurrentConfigurations([changed])
                    case .presentation:
                        var changed = configuration
                        changed.accountLabel = "Renamed Codex"
                        changed.groupID = "work"
                        changed.showsHistory = false
                        service.updateCurrentConfigurations([changed])
                    }

                    if mutation == .presentation {
                        XCTAssertEqual(service.results, [cached], assertionLabel)
                    } else {
                        XCTAssertTrue(service.results.isEmpty, assertionLabel)
                        XCTAssertTrue(service.incompleteRefreshAccountIDs.isEmpty, assertionLabel)
                    }

                    await provider.release()
                    let invocation = await refresh.value

                    if mutation == .presentation {
                        switch invocation {
                        case .batch(let completed):
                            XCTAssertTrue(completed, assertionLabel)
                        case .single(let returned):
                            XCTAssertNotNil(returned, assertionLabel)
                        }

                        let stored = try XCTUnwrap(service.results.first, assertionLabel)
                        switch providerOutcome {
                        case .success:
                            XCTAssertEqual(stored, fresh, assertionLabel)
                            XCTAssertTrue(service.incompleteRefreshAccountIDs.isEmpty, assertionLabel)
                        case .failure:
                            XCTAssertEqual(stored.bars, cached.bars, assertionLabel)
                            XCTAssertTrue(stored.subtitle.contains("Suspended failure"), assertionLabel)
                            XCTAssertTrue(stored.isIncompleteRefresh, assertionLabel)
                            XCTAssertEqual(service.incompleteRefreshAccountIDs, [configuration.id], assertionLabel)
                        }
                    } else {
                        switch invocation {
                        case .batch(let completed):
                            XCTAssertFalse(completed, assertionLabel)
                        case .single(let returned):
                            XCTAssertNil(returned, assertionLabel)
                        }
                        XCTAssertTrue(service.results.isEmpty, assertionLabel)
                        XCTAssertTrue(service.incompleteRefreshAccountIDs.isEmpty, assertionLabel)
                    }
                }
            }
        }
    }

    @MainActor
    func testBatchRevalidatesEarlyCompletionsBeforeApplyingTheBatch() async {
        let completedConfiguration = ProviderAccountConfiguration(
            id: "codex.completed-early",
            providerID: .codex,
            accountLabel: "Old Codex",
            authMethod: .browserSession,
            oauthClientID: "client-one"
        )
        let pendingConfiguration = ProviderAccountConfiguration(
            id: "cursor.pending",
            providerID: .cursor,
            accountLabel: "Cursor",
            authMethod: .browserSession
        )
        let completedResult = ProviderUsageResult(
            accountID: completedConfiguration.id,
            providerID: .codex,
            title: completedConfiguration.displayName,
            subtitle: "Obsolete early completion",
            bars: [],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let pendingResult = ProviderUsageResult(
            accountID: pendingConfiguration.id,
            providerID: .cursor,
            title: pendingConfiguration.displayName,
            subtitle: "Current completion",
            bars: [],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let completedProvider = GatedUsageProvider(
            providerID: .codex,
            outcome: .result(completedResult)
        )
        let pendingProvider = GatedUsageProvider(
            providerID: .cursor,
            outcome: .result(pendingResult)
        )
        let service = UsageRefreshService(providers: [completedProvider, pendingProvider])
        service.updateCurrentConfigurations([completedConfiguration, pendingConfiguration])

        let refresh = Task { @MainActor in
            await service.refresh(configurations: [completedConfiguration, pendingConfiguration])
        }
        let completedDidStart = await completedProvider.waitUntilStarted()
        let pendingDidStart = await pendingProvider.waitUntilStarted()
        XCTAssertTrue(completedDidStart)
        XCTAssertTrue(pendingDidStart)

        await completedProvider.release()
        let completedBeforeMutation = await completedProvider.waitUntilCompleted()
        XCTAssertTrue(completedBeforeMutation)

        var changedConfiguration = completedConfiguration
        changedConfiguration.oauthClientID = "client-two"
        service.updateCurrentConfigurations([changedConfiguration, pendingConfiguration])
        await pendingProvider.release()

        let completed = await refresh.value
        XCTAssertFalse(completed)
        XCTAssertEqual(service.results, [pendingResult])
        XCTAssertTrue(service.incompleteRefreshAccountIDs.isEmpty)
    }

}

private enum RefreshTestPath: String, CaseIterable {
    case batch
    case single
}

private enum RefreshTestProviderOutcome: String, CaseIterable {
    case success
    case failure
}

private enum RefreshTestMutation: String, CaseIterable {
    case remove
    case disable
    case credential
    case refreshInput
    case presentation
}

private enum RefreshTestInvocation {
    case batch(Bool)
    case single(ProviderUsageResult?)
}
