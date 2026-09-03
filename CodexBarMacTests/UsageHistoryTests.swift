import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class UsageHistoryTests: XCTestCase {
    deinit {}

    @MainActor
    func testUsageHistoryStoreRecordsAndPersistsSnapshots() throws {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 42, limit: 100)],
            fetchedAt: fetchedAt
        )

        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: fetchedAt)

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.snapshots.count, 1)
        XCTAssertEqual(reloadedStore.snapshots.first?.accountID, "codex.personal")
        let fractionUsed = try XCTUnwrap(reloadedStore.snapshots.first?.bars.first?.fractionUsed)
        XCTAssertEqual(fractionUsed, 0.42, accuracy: 0.0001)
        XCTAssertNil(reloadedStore.snapshots.first?.creditsRemaining)
    }

    @MainActor
    func testUsageHistoryStoreEnforcesSamplingIntervalPerAccountAndAtBoundary() {
        let suiteName = "CodexBarMacTests.HistorySampling.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        var encodingCount = 0
        let store = UsageHistoryStore(defaults: defaults) { snapshots in
            encodingCount += 1
            return try JSONEncoder().encode(snapshots)
        }

        store.record(
            results: [makeHistoryResult(accountID: "codex.personal", fetchedAt: firstFetch, used: 20)],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: firstFetch.addingTimeInterval(60 * 60),
                    used: 30
                ),
                makeHistoryResult(
                    accountID: "codex.work",
                    fetchedAt: firstFetch.addingTimeInterval(60 * 60),
                    used: 40
                ),
            ],
            now: firstFetch.addingTimeInterval(60 * 60),
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        XCTAssertEqual(encodingCount, 2)

        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: firstFetch.addingTimeInterval(90 * 60),
                    used: 45
                ),
            ],
            now: firstFetch.addingTimeInterval(90 * 60),
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        XCTAssertEqual(encodingCount, 2, "A skipped sample must not rewrite unchanged history.")

        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: firstFetch.addingTimeInterval(2 * 60 * 60),
                    used: 50
                ),
            ],
            now: firstFetch.addingTimeInterval(2 * 60 * 60),
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(encodingCount, 3)
        XCTAssertEqual(
            store.snapshots(for: "codex.personal").compactMap { $0.bars.first?.used },
            [20, 50]
        )
        XCTAssertEqual(
            store.snapshots(for: "codex.work").compactMap { $0.bars.first?.used },
            [40]
        )
    }

    @MainActor
    func testUsageHistoryPresentsFreshResultInsideSamplingIntervalWithoutPersistingIt() {
        let suiteName = "CodexBarMacTests.HistoryPresentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let storedResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: firstFetch,
            used: 8
        )
        let freshResult = makeHistoryResult(
            accountID: storedResult.accountID,
            fetchedAt: firstFetch.addingTimeInterval(101 * 60),
            used: 43
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [storedResult],
            now: storedResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [freshResult],
            now: freshResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots.first?.bars.first?.used, 8)
        XCTAssertEqual(store.historySeries(for: freshResult).points.map(\.value), [0.08, 0.43])
        XCTAssertEqual(
            store.historySeriesOptions(for: freshResult).first?.series.points.map(\.value),
            [0.08, 0.43]
        )
        XCTAssertEqual(
            store.trendSummary(for: freshResult, now: freshResult.fetchedAt)?.points,
            [0.08, 0.43]
        )
        XCTAssertEqual(store.snapshots.count, 1)
    }

    @MainActor
    func testUsageHistoryReplacesSameTimestampAndPreservesMissingMonetaryMetric() {
        let suiteName = "CodexBarMacTests.HistoryReplacement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let spent = ProviderMonetaryMetric(
            kind: .spent,
            label: "Usage credits spent",
            minorUnits: 1_500,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let storedResult = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Stored spend",
            bars: [],
            monetaryMetrics: [
                spent,
                ProviderMonetaryMetric(
                    kind: .spendLimit,
                    label: "Spend limit",
                    minorUnits: 1_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: fetchedAt
        )
        let currentResult = ProviderUsageResult(
            accountID: storedResult.accountID,
            providerID: storedResult.providerID,
            title: storedResult.title,
            subtitle: "Current spend",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: spent.label,
                    minorUnits: 5_000,
                    currencyCode: spent.currencyCode,
                    decimalPlaces: 3
                ),
            ],
            fetchedAt: fetchedAt
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [storedResult], now: fetchedAt)

        let spentSeries = store.historySeriesOptions(for: currentResult)
            .first(where: { $0.label == spent.label })?.series

        XCTAssertEqual(spentSeries?.points.map(\.value), [5])
        XCTAssertEqual(spentSeries?.decimalPlaces, 3)
        XCTAssertEqual(spentSeries?.points.first?.severity, .critical)
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots.first?.monetaryMetrics?.map(\.kind), [.spent, .spendLimit])
        XCTAssertEqual(store.snapshots.first?.monetaryMetrics?.first?.minorUnits, 1_500)
    }

    @MainActor
    func testUsageHistoryDoesNotPresentOlderIncompleteOrOutOfRangeResult() {
        let suiteName = "CodexBarMacTests.HistoryPresentationGuards.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let secondFetch = firstFetch.addingTimeInterval(3 * 60 * 60)
        let first = makeHistoryResult(accountID: "codex.personal", fetchedAt: firstFetch, used: 8)
        let second = makeHistoryResult(accountID: first.accountID, fetchedAt: secondFetch, used: 20)
        let older = makeHistoryResult(
            accountID: first.accountID,
            fetchedAt: secondFetch.addingTimeInterval(-60),
            used: 43
        )
        let incomplete = ProviderUsageResult(
            accountID: first.accountID,
            providerID: first.providerID,
            title: first.title,
            subtitle: "Refresh failed",
            bars: [UsageBar(label: "5h limit", used: 43, limit: 100)],
            isIncompleteRefresh: true,
            fetchedAt: secondFetch.addingTimeInterval(60)
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [first, second], now: secondFetch)

        XCTAssertEqual(store.historySeries(for: older).points.map(\.value), [0.08, 0.2])
        XCTAssertEqual(store.historySeries(for: incomplete).points.map(\.value), [0.08, 0.2])
        XCTAssertTrue(
            store.historySeries(
                for: incomplete,
                since: incomplete.fetchedAt.addingTimeInterval(1)
            ).points.isEmpty
        )
    }

    @MainActor
    func testUsageHistoryPresentsFreshResultOnlyInsideSelectedRange() {
        let suiteName = "CodexBarMacTests.HistoryPresentationRange.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let storedResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: firstFetch,
            used: 8
        )
        let freshResult = makeHistoryResult(
            accountID: storedResult.accountID,
            fetchedAt: firstFetch.addingTimeInterval(101 * 60),
            used: 43
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [storedResult], now: firstFetch)

        XCTAssertEqual(
            store.historySeries(
                for: freshResult,
                since: firstFetch.addingTimeInterval(1)
            ).points.map(\.value),
            [0.43]
        )
        XCTAssertTrue(
            store.historySeries(
                for: freshResult,
                since: freshResult.fetchedAt.addingTimeInterval(1)
            ).points.isEmpty
        )
    }

    @MainActor
    func testUsageHistoryMapsLegacyCursorMetricsIntoFreshSemanticSeries() {
        let suiteName = "CodexBarMacTests.HistoryPresentationCursor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let storedResult = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Stored usage",
            bars: [
                UsageBar(stableKey: "total", label: "Total", used: 8, limit: 100),
                UsageBar(stableKey: "api", label: "API", used: 90, limit: 100),
            ],
            fetchedAt: firstFetch
        )
        let currentResult = ProviderUsageResult(
            accountID: storedResult.accountID,
            providerID: storedResult.providerID,
            title: storedResult.title,
            subtitle: "Fresh usage",
            bars: [
                UsageBar(stableKey: "other-models", label: "Other Models", used: 100, limit: 100),
                UsageBar(stableKey: "cursor-models", label: "Cursor Models", used: 43, limit: 100),
            ],
            fetchedAt: firstFetch.addingTimeInterval(101 * 60)
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(
            results: [storedResult],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [currentResult],
            now: currentResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        let options = store.historySeriesOptions(for: currentResult)
        XCTAssertEqual(store.historySeries(for: currentResult).points.map(\.value), [0.08, 1])
        XCTAssertEqual(
            options.first(where: { $0.id == "usage.total" })?.series.points.map(\.value),
            [0.08]
        )
        XCTAssertEqual(
            options.first(where: { $0.id == "usage.other-models" })?.series.points.map(\.value),
            [0.9, 1]
        )
        XCTAssertEqual(
            options.first(where: { $0.id == "usage.cursor-models" })?.series.points.map(\.value),
            [0.43]
        )
        XCTAssertEqual(store.snapshots.count, 1)
    }

    @MainActor
    func testUsageHistoryPresentsFreshBalanceAndMonetaryValuesWithoutPersistingThem() {
        let suiteName = "CodexBarMacTests.HistoryPresentationBalances.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        func result(at date: Date, balance: Double, headroom: Decimal) -> ProviderUsageResult {
            ProviderUsageResult(
                accountID: "claude.personal",
                providerID: .claude,
                title: "Claude",
                subtitle: "Balance",
                bars: [],
                creditsRemaining: balance,
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .remainingHeadroom,
                        label: "Remaining spend headroom",
                        minorUnits: headroom,
                        currencyCode: "USD",
                        decimalPlaces: 2
                    ),
                ],
                fetchedAt: date
            )
        }
        let storedResult = result(at: firstFetch, balance: 8, headroom: 9_000)
        let currentResult = result(
            at: firstFetch.addingTimeInterval(101 * 60),
            balance: 43,
            headroom: 8_750
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(
            results: [storedResult],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [currentResult],
            now: currentResult.fetchedAt,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        let options = store.historySeriesOptions(for: currentResult)
        XCTAssertEqual(store.historySeries(for: currentResult).points.map(\.value), [8, 43])
        XCTAssertEqual(
            options.first(where: { $0.label == "Remaining spend headroom" })?
                .series.points.map(\.value),
            [90, 87.5]
        )
        XCTAssertEqual(store.snapshots.count, 1)
        XCTAssertEqual(store.snapshots.first?.creditsRemaining, 8)
        XCTAssertEqual(store.snapshots.first?.monetaryMetrics?.first?.minorUnits, 9_000)
    }

    @MainActor
    func testUsageHistoryStoreDoesNotRewriteEqualTimeSnapshotsAfterReload() throws {
        let suiteName = "CodexBarMacTests.HistorySamplingReload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let persistedSnapshots = [
            UsageHistorySnapshot(
                result: makeHistoryResult(accountID: "codex.work", fetchedAt: firstFetch, used: 30)
            ),
            UsageHistorySnapshot(
                result: makeHistoryResult(accountID: "codex.personal", fetchedAt: firstFetch, used: 20)
            ),
        ]
        defaults.set(
            try JSONEncoder().encode(persistedSnapshots),
            forKey: "usageHistorySnapshots"
        )
        var encodingCount = 0
        let store = UsageHistoryStore(defaults: defaults) { snapshots in
            encodingCount += 1
            return try JSONEncoder().encode(snapshots)
        }
        let skippedFetch = firstFetch.addingTimeInterval(60 * 60)

        XCTAssertEqual(store.snapshots.map(\.accountID), ["codex.personal", "codex.work"])

        store.record(
            results: [
                makeHistoryResult(accountID: "codex.work", fetchedAt: skippedFetch, used: 40),
                makeHistoryResult(accountID: "codex.personal", fetchedAt: skippedFetch, used: 50),
            ],
            now: skippedFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(encodingCount, 0)
        XCTAssertEqual(store.snapshots.map(\.accountID), ["codex.personal", "codex.work"])
    }

    @MainActor
    func testUsageHistoryStoreAppliesIntervalChangesToFutureSamplesOnly() {
        let suiteName = "CodexBarMacTests.HistorySamplingChange.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let changedFetch = firstFetch.addingTimeInterval(3 * 60 * 60)
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [makeHistoryResult(accountID: "codex.personal", fetchedAt: firstFetch, used: 20)],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.fourHours.seconds
        )
        store.record(
            results: [makeHistoryResult(accountID: "codex.personal", fetchedAt: changedFetch, used: 30)],
            now: changedFetch,
            samplingInterval: HistorySamplingInterval.fourHours.seconds
        )
        XCTAssertEqual(store.snapshots(for: "codex.personal").count, 1)

        store.record(
            results: [makeHistoryResult(accountID: "codex.personal", fetchedAt: changedFetch, used: 30)],
            now: changedFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(
            store.snapshots(for: "codex.personal").compactMap { $0.bars.first?.used },
            [20, 30]
        )
    }

    @MainActor
    func testUsageHistoryStoreRecordsAccountAfterSuccessfulSamplingGap() {
        let suiteName = "CodexBarMacTests.HistorySamplingRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [
                makeHistoryResult(accountID: "codex.personal", fetchedAt: firstFetch, used: 20),
                makeHistoryResult(accountID: "codex.work", fetchedAt: firstFetch, used: 30),
            ],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: firstFetch.addingTimeInterval(60 * 60),
                    used: 40
                ),
            ],
            now: firstFetch.addingTimeInterval(60 * 60),
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        store.record(
            results: [
                makeHistoryResult(
                    accountID: "codex.work",
                    fetchedAt: firstFetch.addingTimeInterval(3 * 60 * 60),
                    used: 50
                ),
            ],
            now: firstFetch.addingTimeInterval(3 * 60 * 60),
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )

        XCTAssertEqual(
            store.snapshots(for: "codex.work").compactMap { $0.bars.first?.used },
            [30, 50]
        )
    }

    @MainActor
    func testAppModelAppliesSamplingToManualAndSingleAccountRefreshes() async throws {
        let suiteName = "CodexBarMacTests.HistorySamplingAppModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        defaults.set(
            try JSONEncoder().encode([configuration]),
            forKey: "providerConfigurations"
        )
        let firstFetch = Date()
        let provider = SequencedUsageProvider(
            providerID: .codex,
            steps: [
                .result(makeHistoryResult(accountID: configuration.id, fetchedAt: firstFetch, used: 20)),
                .result(
                    makeHistoryResult(
                        accountID: configuration.id,
                        fetchedAt: firstFetch.addingTimeInterval(60 * 60),
                        used: 30
                    )
                ),
                .result(
                    makeHistoryResult(
                        accountID: configuration.id,
                        fetchedAt: firstFetch.addingTimeInterval(2 * 60 * 60),
                        used: 40
                    )
                ),
            ]
        )
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: UsageRefreshService(providers: [provider]),
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(historyStore.snapshots.count, 1)
        XCTAssertEqual(model.displayedResults.first?.fetchedAt, firstFetch.addingTimeInterval(60 * 60))

        let singleAccountResult = await model.refreshAccount(configuration)

        XCTAssertEqual(singleAccountResult?.fetchedAt, firstFetch.addingTimeInterval(2 * 60 * 60))
        XCTAssertEqual(
            historyStore.snapshots(for: configuration.id).compactMap { $0.bars.first?.used },
            [20, 40]
        )
    }

    @MainActor
    func testAppModelAppliesSamplingAfterAutomaticRefreshCompletion() async throws {
        let suiteName = "CodexBarMacTests.HistorySamplingAutoRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        defaults.set(
            try JSONEncoder().encode([configuration]),
            forKey: "providerConfigurations"
        )
        let firstFetch = Date()
        let firstResult = makeHistoryResult(
            accountID: configuration.id,
            fetchedAt: firstFetch,
            used: 20
        )
        let automaticResult = makeHistoryResult(
            accountID: configuration.id,
            fetchedAt: firstFetch.addingTimeInterval(60 * 60),
            used: 30
        )
        let sleeper = OneShotAutoRefreshSleeper()
        let refreshService = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .codex, result: automaticResult)],
            sleepBeforeAutoRefresh: { seconds in
                try await sleeper.sleep(for: seconds)
            }
        )
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        configurationStore.updateAutoRefreshInterval(.oneMinute)
        let historyStore = UsageHistoryStore(defaults: defaults)
        historyStore.record(
            results: [firstResult],
            now: firstFetch,
            samplingInterval: HistorySamplingInterval.twoHours.seconds
        )
        let model = AppModel(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )
        defer { refreshService.stopAutoRefresh() }

        model.updateAutoRefresh()
        for _ in 0..<200 where model.displayedResults.first?.fetchedAt != automaticResult.fetchedAt {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.displayedResults.first?.fetchedAt, automaticResult.fetchedAt)
        XCTAssertEqual(
            historyStore.snapshots(for: configuration.id).compactMap { $0.bars.first?.used },
            [20]
        )
    }

    @MainActor
    func testAppModelRecordsOnlyFreshBalanceFromManualPartialRefresh() async throws {
        let suiteName = "CodexBarMacTests.HistoryPartialBalance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        defaults.set(try JSONEncoder().encode([configuration]), forKey: "providerConfigurations")
        let cachedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let refreshedAt = cachedAt.addingTimeInterval(60)
        let cached = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "Usage and balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 20, limit: 100)],
            creditsRemaining: 12,
            cacheIdentity: "history-partial-account",
            fetchedAt: cachedAt
        )
        let balanceOnly = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "ZEN credit balance",
            bars: [],
            creditsRemaining: 9,
            preservesCachedBarsOnIncompleteRefresh: true,
            cacheIdentity: "history-partial-account",
            isIncompleteRefresh: true,
            fetchedAt: refreshedAt
        )
        let refreshService = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .openCodeZen, result: balanceOnly)],
            initialResults: [cached]
        )
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        await model.refresh()

        XCTAssertTrue(refreshService.successfulRefreshResults.isEmpty)
        XCTAssertEqual(model.displayedResults.first?.bars, cached.bars)
        XCTAssertEqual(historyStore.snapshots.count, 1)
        XCTAssertTrue(historyStore.snapshots[0].bars.isEmpty)
        XCTAssertEqual(historyStore.snapshots[0].creditsRemaining, 9)
        XCTAssertEqual(historyStore.snapshots[0].capturedAt, refreshedAt)
    }

    @MainActor
    func testAppModelRecordsOnlyFreshUsageFromSingleAccountPartialRefresh() async throws {
        let suiteName = "CodexBarMacTests.HistoryPartialUsage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        defaults.set(try JSONEncoder().encode([configuration]), forKey: "providerConfigurations")
        let cachedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let refreshedAt = cachedAt.addingTimeInterval(60)
        let cached = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "Usage and balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 20, limit: 100)],
            creditsRemaining: 12,
            cacheIdentity: "history-partial-account",
            fetchedAt: cachedAt
        )
        let usageOnly = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "OpenCode Go usage",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 35, limit: 100)],
            preservesCachedCreditsOnIncompleteRefresh: true,
            cacheIdentity: "history-partial-account",
            isIncompleteRefresh: true,
            fetchedAt: refreshedAt
        )
        let refreshService = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .openCodeZen, result: usageOnly)],
            initialResults: [cached]
        )
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        let returnedResult = await model.refreshAccount(configuration)

        XCTAssertEqual(returnedResult?.fetchedAt, refreshedAt)
        XCTAssertEqual(returnedResult?.bars.first?.used, 35)
        XCTAssertEqual(returnedResult?.creditsRemaining, 12)
        XCTAssertEqual(model.displayedResults.first?.creditsRemaining, 12)
        XCTAssertEqual(historyStore.snapshots.count, 1)
        XCTAssertEqual(historyStore.snapshots[0].bars.first?.used, 35)
        XCTAssertNil(historyStore.snapshots[0].creditsRemaining)
        XCTAssertEqual(historyStore.snapshots[0].capturedAt, refreshedAt)
    }

    @MainActor
    func testAppModelSkipsLastKnownDataAfterAutomaticTotalFailure() async throws {
        let suiteName = "CodexBarMacTests.HistoryTotalFailure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        defaults.set(try JSONEncoder().encode([configuration]), forKey: "providerConfigurations")
        let cachedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let cached = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "Usage and balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 20, limit: 100)],
            creditsRemaining: 12,
            cacheIdentity: "history-partial-account",
            fetchedAt: cachedAt
        )
        let totalFailure = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "Temporary outage",
            bars: [],
            cacheIdentity: "history-partial-account",
            isIncompleteRefresh: true,
            fetchedAt: cachedAt.addingTimeInterval(60)
        )
        let sleeper = OneShotAutoRefreshSleeper()
        let refreshService = UsageRefreshService(
            providers: [StubUsageProvider(providerID: .openCodeZen, result: totalFailure)],
            initialResults: [cached],
            sleepBeforeAutoRefresh: { seconds in
                try await sleeper.sleep(for: seconds)
            }
        )
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        configurationStore.updateAutoRefreshInterval(.oneMinute)
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )
        defer { refreshService.stopAutoRefresh() }

        model.updateAutoRefresh()
        for _ in 0..<200 where model.lastRefreshedAt == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNotNil(model.lastRefreshedAt)
        XCTAssertEqual(model.displayedResults.first?.fetchedAt, cachedAt)
        XCTAssertEqual(
            model.displayedResults.first?.historyFreshness,
            ProviderUsageHistoryFreshness.none
        )
        XCTAssertTrue(historyStore.snapshots.isEmpty)
        XCTAssertTrue(historyStore.dailySnapshots.isEmpty)
    }

    @MainActor
    func testUsageHistoryStoreTreatsAbsentStorageAsEmptyHistory() {
        let suiteName = "CodexBarMacTests.HistoryAbsent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.dailySnapshots.isEmpty)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.requiresRecovery)
        XCTAssertNil(defaults.object(forKey: "usageHistorySnapshots"))
        XCTAssertNil(defaults.object(forKey: "usageHistoryDailySnapshots"))
    }

    @MainActor
    func testUsageHistoryStoreMigratesExistingDenseHistoryWithoutInventingDailyData() throws {
        let suiteName = "CodexBarMacTests.HistoryDailyMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let existingSnapshot = UsageHistorySnapshot(
            result: makeHistoryResult(
                accountID: "codex.personal",
                fetchedAt: fetchedAt,
                used: 20
            )
        )
        defaults.set(
            try JSONEncoder().encode([existingSnapshot]),
            forKey: "usageHistorySnapshots"
        )

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertEqual(store.snapshots, [existingSnapshot])
        XCTAssertTrue(store.dailySnapshots.isEmpty)
        XCTAssertNil(defaults.object(forKey: "usageHistoryDailySnapshots"))

        let latestResult = makeHistoryResult(
            accountID: existingSnapshot.accountID,
            fetchedAt: fetchedAt.addingTimeInterval(60 * 60),
            used: 35
        )
        store.record(results: [latestResult], now: latestResult.fetchedAt, samplingInterval: 2 * 60 * 60)

        XCTAssertEqual(store.snapshots, [existingSnapshot])
        XCTAssertEqual(store.dailySnapshots.compactMap { $0.bars.first?.used }, [35])
        XCTAssertNotNil(defaults.data(forKey: "usageHistoryDailySnapshots"))
    }

    @MainActor
    func testUsageHistoryStorePreservesMalformedDataUntilExplicitReset() throws {
        let suiteName = "CodexBarMacTests.HistoryRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformedData = Data(#"{"snapshots":"not-an-array"}"#.utf8)
        defaults.set(malformedData, forKey: "usageHistorySnapshots")
        defaults.set("preserve-me", forKey: "unrelatedSetting")
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 42, limit: 100)],
            fetchedAt: fetchedAt
        )
        let validDailyData = try JSONEncoder().encode([UsageHistorySnapshot(result: result)])
        defaults.set(validDailyData, forKey: "usageHistoryDailySnapshots")

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.dailySnapshots.isEmpty)
        XCTAssertTrue(store.requiresRecovery)
        XCTAssertEqual(
            store.lastError,
            "Saved usage history could not be read. Reset history to resume recording."
        )

        store.record(results: [result], now: fetchedAt)
        store.removeSnapshotsForMissingAccounts(validAccountIDs: [result.accountID], now: fetchedAt)

        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), malformedData)
        XCTAssertEqual(defaults.data(forKey: "usageHistoryDailySnapshots"), validDailyData)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.dailySnapshots.isEmpty)
        XCTAssertTrue(store.requiresRecovery)
        XCTAssertNotNil(store.lastError)

        store.discardCorruptedHistory()

        XCTAssertNil(defaults.object(forKey: "usageHistorySnapshots"))
        XCTAssertNil(defaults.object(forKey: "usageHistoryDailySnapshots"))
        XCTAssertEqual(defaults.string(forKey: "unrelatedSetting"), "preserve-me")
        XCTAssertFalse(store.requiresRecovery)
        XCTAssertNil(store.lastError)

        store.record(results: [result], now: fetchedAt)

        XCTAssertEqual(store.snapshots.map(\.accountID), [result.accountID])
        XCTAssertEqual(store.dailySnapshots.map(\.accountID), [result.accountID])
        XCTAssertNotNil(defaults.data(forKey: "usageHistorySnapshots"))
        XCTAssertNotNil(defaults.data(forKey: "usageHistoryDailySnapshots"))
        XCTAssertNil(store.lastError)

        store.removeSnapshotsForMissingAccounts(validAccountIDs: [], now: fetchedAt)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.dailySnapshots.isEmpty)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [UsageHistorySnapshot].self,
                from: try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
            ),
            []
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [UsageHistorySnapshot].self,
                from: try XCTUnwrap(defaults.data(forKey: "usageHistoryDailySnapshots"))
            ),
            []
        )
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testUsageHistoryStorePreservesDuplicateSnapshotIDsUntilExplicitReset() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let originalSnapshot = UsageHistorySnapshot(
            result: makeHistoryResult(
                accountID: "codex.personal",
                fetchedAt: fetchedAt,
                used: 20
            )
        )
        let conflictingSnapshot = UsageHistorySnapshot(
            result: makeHistoryResult(
                accountID: "codex.personal",
                fetchedAt: fetchedAt,
                used: 80
            )
        )

        for (scenario, snapshots) in [
            ("identical", [originalSnapshot, originalSnapshot]),
            ("conflicting", [originalSnapshot, conflictingSnapshot]),
        ] {
            let suiteName = "CodexBarMacTests.HistoryDuplicateIDs.\(scenario).\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let damagedData = try JSONEncoder().encode(snapshots)
            defaults.set(damagedData, forKey: "usageHistorySnapshots")
            let store = UsageHistoryStore(defaults: defaults)

            XCTAssertTrue(store.snapshots.isEmpty, scenario)
            XCTAssertTrue(store.requiresRecovery, scenario)
            XCTAssertEqual(
                store.lastError,
                "Saved usage history could not be read. Reset history to resume recording.",
                scenario
            )

            let replacementDate = fetchedAt.addingTimeInterval(60)
            let replacementResult = makeHistoryResult(
                accountID: "codex.personal",
                fetchedAt: replacementDate,
                used: 40
            )
            store.record(results: [replacementResult], now: replacementDate)
            store.removeSnapshotsForMissingAccounts(validAccountIDs: [], now: replacementDate)

            XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), damagedData, scenario)
            XCTAssertTrue(store.snapshots.isEmpty, scenario)
            XCTAssertTrue(store.requiresRecovery, scenario)

            store.discardCorruptedHistory()
            store.record(results: [replacementResult], now: replacementDate)

            XCTAssertFalse(store.requiresRecovery, scenario)
            XCTAssertNil(store.lastError, scenario)
            XCTAssertEqual(store.snapshots, [UsageHistorySnapshot(result: replacementResult)], scenario)
            XCTAssertNotEqual(defaults.data(forKey: "usageHistorySnapshots"), damagedData, scenario)
        }
    }

    @MainActor
    func testUsageHistoryStorePreservesNonDataValueUntilExplicitReset() {
        let suiteName = "CodexBarMacTests.HistoryNonData.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let damagedValue = ["unexpected": "value"]
        defaults.set(damagedValue, forKey: "usageHistorySnapshots")

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.requiresRecovery)
        XCTAssertNotNil(store.lastError)
        XCTAssertEqual(
            defaults.dictionary(forKey: "usageHistorySnapshots")?["unexpected"] as? String,
            damagedValue["unexpected"]
        )

        store.discardCorruptedHistory()

        XCTAssertNil(defaults.object(forKey: "usageHistorySnapshots"))
        XCTAssertFalse(store.requiresRecovery)
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testUsageHistoryStorePreservesDenseAndDuplicateDailyDataUntilReset() throws {
        let suiteName = "CodexBarMacTests.HistoryDuplicateDailyIDs.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snapshot = UsageHistorySnapshot(
            result: makeHistoryResult(
                accountID: "codex.personal",
                fetchedAt: Date(timeIntervalSince1970: 1_788_475_200),
                used: 20
            )
        )
        let denseData = try JSONEncoder().encode([snapshot])
        let damagedDailyData = try JSONEncoder().encode([snapshot, snapshot])
        defaults.set(denseData, forKey: "usageHistorySnapshots")
        defaults.set(damagedDailyData, forKey: "usageHistoryDailySnapshots")

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.dailySnapshots.isEmpty)
        XCTAssertTrue(store.requiresRecovery)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), denseData)
        XCTAssertEqual(defaults.data(forKey: "usageHistoryDailySnapshots"), damagedDailyData)

        store.discardCorruptedHistory()

        XCTAssertNil(defaults.object(forKey: "usageHistorySnapshots"))
        XCTAssertNil(defaults.object(forKey: "usageHistoryDailySnapshots"))
        XCTAssertFalse(store.requiresRecovery)
    }

    @MainActor
    func testAppModelStartupPruningAndRefreshPreserveDamagedUsageHistory() async {
        let suiteName = "CodexBarMacTests.HistoryAppModelRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformedData = Data("not valid usage history".utf8)
        defaults.set(malformedData, forKey: "usageHistorySnapshots")
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 42, limit: 100)],
            fetchedAt: fetchedAt
        )
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: UsageRefreshService(
                providers: [StubUsageProvider(providerID: .codex, result: result)]
            ),
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        XCTAssertEqual(
            defaults.data(forKey: "usageHistorySnapshots"),
            malformedData,
            "The immediate configuration subscription must not replace damaged history."
        )
        XCTAssertTrue(historyStore.requiresRecovery)

        await model.refresh()

        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), malformedData)
        XCTAssertTrue(historyStore.snapshots.isEmpty)
        XCTAssertTrue(historyStore.requiresRecovery)
        XCTAssertNotNil(historyStore.lastError)
    }

    @MainActor
    func testAppModelRefreshPathsPreserveDuplicateSnapshotIDs() async throws {
        let suiteName = "CodexBarMacTests.HistoryDuplicateIDsAppModel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        defaults.set(try JSONEncoder().encode([configuration]), forKey: "providerConfigurations")
        let damagedDate = Date(timeIntervalSince1970: 1_788_475_200)
        let damagedSnapshot = UsageHistorySnapshot(
            result: makeHistoryResult(
                accountID: configuration.id,
                fetchedAt: damagedDate,
                used: 10
            )
        )
        let damagedData = try JSONEncoder().encode([damagedSnapshot, damagedSnapshot])
        defaults.set(damagedData, forKey: "usageHistorySnapshots")
        let manualResult = makeHistoryResult(
            accountID: configuration.id,
            fetchedAt: damagedDate.addingTimeInterval(60),
            used: 20
        )
        let singleAccountResult = makeHistoryResult(
            accountID: configuration.id,
            fetchedAt: damagedDate.addingTimeInterval(120),
            used: 30
        )
        let automaticResult = makeHistoryResult(
            accountID: configuration.id,
            fetchedAt: damagedDate.addingTimeInterval(180),
            used: 40
        )
        let sleeper = OneShotAutoRefreshSleeper()
        let refreshService = UsageRefreshService(
            providers: [
                SequencedUsageProvider(
                    providerID: .codex,
                    steps: [
                        .result(manualResult),
                        .result(singleAccountResult),
                        .result(automaticResult),
                    ]
                ),
            ],
            sleepBeforeAutoRefresh: { seconds in
                try await sleeper.sleep(for: seconds)
            }
        )
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        configurationStore.updateAutoRefreshInterval(.oneMinute)
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )
        defer { refreshService.stopAutoRefresh() }

        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), damagedData)
        XCTAssertTrue(historyStore.requiresRecovery)

        await model.refresh()
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), damagedData)

        let refreshedAccount = await model.refreshAccount(configuration)
        XCTAssertEqual(refreshedAccount?.fetchedAt, singleAccountResult.fetchedAt)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), damagedData)

        model.updateAutoRefresh()
        for _ in 0..<200 where model.displayedResults.first?.fetchedAt != automaticResult.fetchedAt {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.displayedResults.first?.fetchedAt, automaticResult.fetchedAt)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), damagedData)
        XCTAssertTrue(historyStore.snapshots.isEmpty)
        XCTAssertTrue(historyStore.requiresRecovery)
    }

    @MainActor
    func testAppModelPreservesHealthyHistoryUntilDamagedAccountDataReplacementCompletes() async throws {
        let suiteName = "CodexBarMacTests.HistoryConfigurationRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = Date()
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex Personal",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 42, limit: 100)],
            fetchedAt: fetchedAt
        )
        let historyWriter = UsageHistoryStore(defaults: defaults)
        historyWriter.record(results: [result], now: fetchedAt)
        let originalHistoryData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
        defaults.set(Data("not valid account data".utf8), forKey: "providerConfigurations")

        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: UsageRefreshService(providers: []),
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        XCTAssertTrue(configurationStore.isConfigurationRecoveryRequired)
        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [result.accountID])
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), originalHistoryData)

        XCTAssertTrue(configurationStore.replaceCorruptedConfigurations())

        XCTAssertFalse(configurationStore.isConfigurationRecoveryRequired)
        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [result.accountID])
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), originalHistoryData)

        model.completeConfigurationRecoveryIfPossible()
        model.invalidateAccounts()
        await model.refreshAfterAccountChange()

        XCTAssertTrue(model.historyStore.snapshots.isEmpty)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [UsageHistorySnapshot].self,
                from: try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
            ),
            []
        )
    }

    @MainActor
    func testAppModelPreservesHistoryForAccountsRestoredDuringConfigurationRecovery() async throws {
        let suiteName = "CodexBarMacTests.HistoryRestoredConfiguration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoredConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let fetchedAt = Date()
        let result = ProviderUsageResult(
            accountID: restoredConfiguration.id,
            providerID: restoredConfiguration.providerID,
            title: restoredConfiguration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            fetchedAt: fetchedAt
        )
        let historyWriter = UsageHistoryStore(defaults: defaults)
        historyWriter.record(results: [result], now: fetchedAt)
        let originalHistoryData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
        defaults.set(Data("not valid account data".utf8), forKey: "providerConfigurations")
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: UsageRefreshService(providers: []),
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        XCTAssertTrue(configurationStore.replaceCorruptedConfigurations())
        XCTAssertTrue(configurationStore.update(restoredConfiguration))

        XCTAssertEqual(configurationStore.configurations.map(\.id), [restoredConfiguration.id])
        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [restoredConfiguration.id])
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), originalHistoryData)

        model.invalidateAccounts()
        await model.refreshAfterAccountChange()

        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [restoredConfiguration.id])
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), originalHistoryData)

        model.completeConfigurationRecoveryIfPossible()

        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [restoredConfiguration.id])
        XCTAssertEqual(
            UsageHistoryStore(defaults: defaults).snapshots.map(\.accountID),
            [restoredConfiguration.id]
        )
    }

    @MainActor
    func testAppModelWaitsForGroupAndAccountRecoveryBeforePruningHistory() throws {
        let suiteName = "CodexBarMacTests.HistoryCombinedRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoredConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let fetchedAt = Date()
        let result = ProviderUsageResult(
            accountID: restoredConfiguration.id,
            providerID: restoredConfiguration.providerID,
            title: restoredConfiguration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            fetchedAt: fetchedAt
        )
        let historyWriter = UsageHistoryStore(defaults: defaults)
        historyWriter.record(results: [result], now: fetchedAt)
        let originalHistoryData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
        defaults.set(Data("not valid account data".utf8), forKey: "providerConfigurations")
        defaults.set(Data("not valid group data".utf8), forKey: "providerAccountGroups")
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: UsageRefreshService(providers: []),
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        XCTAssertTrue(configurationStore.replaceCorruptedConfigurations())
        XCTAssertTrue(configurationStore.isGroupRecoveryRequired)

        model.completeConfigurationRecoveryIfPossible()

        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [restoredConfiguration.id])
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), originalHistoryData)

        XCTAssertTrue(configurationStore.replaceCorruptedGroups())
        XCTAssertTrue(configurationStore.update(restoredConfiguration))
        model.completeConfigurationRecoveryIfPossible()

        XCTAssertFalse(configurationStore.isPersistenceRecoveryRequired)
        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [restoredConfiguration.id])
        XCTAssertEqual(
            UsageHistoryStore(defaults: defaults).snapshots.map(\.accountID),
            [restoredConfiguration.id]
        )
    }

    @MainActor
    func testAppModelPreservesHistoryAcrossPartialRecoveryRelaunch() throws {
        let suiteName = "CodexBarMacTests.HistoryPartialRecoveryRelaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoredConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let fetchedAt = Date()
        let result = ProviderUsageResult(
            accountID: restoredConfiguration.id,
            providerID: restoredConfiguration.providerID,
            title: restoredConfiguration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            fetchedAt: fetchedAt
        )
        let historyWriter = UsageHistoryStore(defaults: defaults)
        historyWriter.record(results: [result], now: fetchedAt)
        let originalHistoryData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
        defaults.set(Data("not valid account data".utf8), forKey: "providerConfigurations")
        defaults.set(Data("not valid group data".utf8), forKey: "providerAccountGroups")
        let recoveryStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )

        XCTAssertTrue(recoveryStore.replaceCorruptedConfigurations())
        XCTAssertTrue(recoveryStore.isGroupRecoveryRequired)

        let reconstructedStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let model = AppModel(
            refreshService: UsageRefreshService(providers: []),
            configurationStore: reconstructedStore,
            historyStore: UsageHistoryStore(defaults: defaults),
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        XCTAssertFalse(reconstructedStore.isConfigurationRecoveryRequired)
        XCTAssertTrue(reconstructedStore.isGroupRecoveryRequired)
        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [restoredConfiguration.id])
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), originalHistoryData)

        XCTAssertTrue(reconstructedStore.replaceCorruptedGroups())
        XCTAssertTrue(reconstructedStore.update(restoredConfiguration))
        model.completeConfigurationRecoveryIfPossible()

        XCTAssertFalse(reconstructedStore.isPersistenceRecoveryRequired)
        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [restoredConfiguration.id])
        XCTAssertEqual(
            UsageHistoryStore(defaults: defaults).snapshots.map(\.accountID),
            [restoredConfiguration.id]
        )
    }

    @MainActor
    func testAppModelPreservesHistoryAcrossAccountRecoveryRelaunch() throws {
        let suiteName = "CodexBarMacTests.HistoryAccountRecoveryRelaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let restoredConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let fetchedAt = Date()
        let result = ProviderUsageResult(
            accountID: restoredConfiguration.id,
            providerID: restoredConfiguration.providerID,
            title: restoredConfiguration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            fetchedAt: fetchedAt
        )
        let historyWriter = UsageHistoryStore(defaults: defaults)
        historyWriter.record(results: [result], now: fetchedAt)
        let originalHistoryData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
        defaults.set(Data("not valid account data".utf8), forKey: "providerConfigurations")
        let recoveryStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )

        XCTAssertTrue(recoveryStore.replaceCorruptedConfigurations())
        XCTAssertFalse(recoveryStore.isPersistenceRecoveryRequired)
        XCTAssertTrue(recoveryStore.isConfigurationRecoveryCompletionPending)

        let reconstructedStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let model = AppModel(
            refreshService: UsageRefreshService(providers: []),
            configurationStore: reconstructedStore,
            historyStore: UsageHistoryStore(defaults: defaults),
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        XCTAssertFalse(reconstructedStore.isPersistenceRecoveryRequired)
        XCTAssertTrue(reconstructedStore.isConfigurationRecoveryCompletionPending)
        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [restoredConfiguration.id])
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), originalHistoryData)

        XCTAssertTrue(reconstructedStore.update(restoredConfiguration))
        model.completeConfigurationRecoveryIfPossible()

        XCTAssertFalse(reconstructedStore.isConfigurationRecoveryCompletionPending)
        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [restoredConfiguration.id])
        XCTAssertEqual(
            UsageHistoryStore(defaults: defaults).snapshots.map(\.accountID),
            [restoredConfiguration.id]
        )
    }

    @MainActor
    func testAppModelValidStartupPrunesHistoryForMissingAccounts() throws {
        let suiteName = "CodexBarMacTests.HistoryValidConfigurationStartup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let retainedConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let deletedConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        defaults.set(
            try JSONEncoder().encode([retainedConfiguration]),
            forKey: "providerConfigurations"
        )
        let fetchedAt = Date()
        let retainedResult = ProviderUsageResult(
            accountID: retainedConfiguration.id,
            providerID: retainedConfiguration.providerID,
            title: retainedConfiguration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            fetchedAt: fetchedAt
        )
        let deletedResult = ProviderUsageResult(
            accountID: deletedConfiguration.id,
            providerID: deletedConfiguration.providerID,
            title: deletedConfiguration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 30, limit: 100)],
            fetchedAt: fetchedAt
        )
        let historyWriter = UsageHistoryStore(defaults: defaults)
        historyWriter.record(results: [retainedResult, deletedResult], now: fetchedAt)
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let historyStore = UsageHistoryStore(defaults: defaults)

        let model = AppModel(
            refreshService: UsageRefreshService(providers: []),
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        XCTAssertFalse(configurationStore.isConfigurationRecoveryRequired)
        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [retainedConfiguration.id])
        XCTAssertEqual(
            UsageHistoryStore(defaults: defaults).snapshots.map(\.accountID),
            [retainedConfiguration.id]
        )
    }

    @MainActor
    func testAppModelPrunesHistoryAfterSuccessfulAccountRemoval() throws {
        let suiteName = "CodexBarMacTests.HistoryAccountRemoval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let retainedConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let removedConfiguration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        defaults.set(
            try JSONEncoder().encode([retainedConfiguration, removedConfiguration]),
            forKey: "providerConfigurations"
        )
        let fetchedAt = Date()
        let retainedResult = ProviderUsageResult(
            accountID: retainedConfiguration.id,
            providerID: retainedConfiguration.providerID,
            title: retainedConfiguration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            fetchedAt: fetchedAt
        )
        let removedResult = ProviderUsageResult(
            accountID: removedConfiguration.id,
            providerID: removedConfiguration.providerID,
            title: removedConfiguration.displayName,
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 30, limit: 100)],
            fetchedAt: fetchedAt
        )
        let historyWriter = UsageHistoryStore(defaults: defaults)
        historyWriter.record(results: [retainedResult, removedResult], now: fetchedAt)
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        let historyStore = UsageHistoryStore(defaults: defaults)
        let model = AppModel(
            refreshService: UsageRefreshService(providers: []),
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )
        XCTAssertEqual(
            Set(model.historyStore.snapshots.map(\.accountID)),
            [retainedConfiguration.id, removedConfiguration.id]
        )

        configurationStore.removeAccount(removedConfiguration)

        XCTAssertEqual(model.historyStore.snapshots.map(\.accountID), [retainedConfiguration.id])
        XCTAssertEqual(
            UsageHistoryStore(defaults: defaults).snapshots.map(\.accountID),
            [retainedConfiguration.id]
        )
    }

    @MainActor
    func testAppModelSkipsHistoryPruningForNonIdentityAccountEdits() throws {
        let suiteName = "CodexBarMacTests.HistoryNonIdentityAccountEdit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        var historyEncodingCount = 0
        let historyStore = UsageHistoryStore(defaults: defaults) { snapshots in
            historyEncodingCount += 1
            return try JSONEncoder().encode(snapshots)
        }
        let model = AppModel(
            refreshService: UsageRefreshService(providers: []),
            configurationStore: configurationStore,
            historyStore: historyStore,
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )
        var configuration = try XCTUnwrap(configurationStore.configurations.first)
        let initialHistoryEncodingCount = historyEncodingCount

        configuration.isEnabled.toggle()
        XCTAssertTrue(configurationStore.update(configuration))

        XCTAssertEqual(historyEncodingCount, initialHistoryEncodingCount)
        XCTAssertTrue(model.historyStore.snapshots.isEmpty)
    }

    @MainActor
    func testUsageHistoryStoreRollsBackEncodingFailureAndRecovers() throws {
        let suiteName = "CodexBarMacTests.HistoryEncoding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstDate = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let firstResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 42, limit: 100)],
            fetchedAt: firstDate
        )
        store.record(results: [firstResult], now: firstDate)
        let previousSnapshots = store.snapshots
        let previousDailySnapshots = store.dailySnapshots
        let previousData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
        let previousDailyData = try XCTUnwrap(defaults.data(forKey: "usageHistoryDailySnapshots"))

        let invalidDate = firstDate.addingTimeInterval(60)
        let invalidResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: .nan, limit: 100)],
            fetchedAt: invalidDate
        )
        store.record(results: [invalidResult], now: invalidDate)

        XCTAssertEqual(store.snapshots, previousSnapshots)
        XCTAssertEqual(store.dailySnapshots, previousDailySnapshots)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), previousData)
        XCTAssertEqual(defaults.data(forKey: "usageHistoryDailySnapshots"), previousDailyData)
        XCTAssertTrue(store.lastError?.hasPrefix("Could not save usage history:") == true)

        let recoveredDate = invalidDate.addingTimeInterval(60)
        let recoveredResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 84, limit: 100)],
            fetchedAt: recoveredDate
        )
        store.record(results: [recoveredResult], now: recoveredDate)

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.snapshots.count, 2)
        XCTAssertEqual(store.dailySnapshots.count, 1)
        XCTAssertNotEqual(defaults.data(forKey: "usageHistorySnapshots"), previousData)
        XCTAssertNotEqual(defaults.data(forKey: "usageHistoryDailySnapshots"), previousDailyData)
        XCTAssertEqual(UsageHistoryStore(defaults: defaults).snapshots, store.snapshots)
        XCTAssertEqual(UsageHistoryStore(defaults: defaults).dailySnapshots, store.dailySnapshots)
    }

    @MainActor
    func testUsageHistoryStoreRollsBackBothLanesWhenDailyEncodingFails() throws {
        let suiteName = "CodexBarMacTests.HistoryDailyEncoding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var shouldFailDailyEncoding = false
        let store = UsageHistoryStore(
            defaults: defaults,
            encodeSnapshots: { try JSONEncoder().encode($0) },
            encodeDailySnapshots: { snapshots in
                if shouldFailDailyEncoding {
                    throw CocoaError(.fileWriteUnknown)
                }
                return try JSONEncoder().encode(snapshots)
            }
        )
        let firstDate = Date(timeIntervalSince1970: 1_788_475_200)
        let firstResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: firstDate,
            used: 20
        )
        store.record(results: [firstResult], now: firstDate)
        let previousSnapshots = store.snapshots
        let previousDailySnapshots = store.dailySnapshots
        let previousData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
        let previousDailyData = try XCTUnwrap(defaults.data(forKey: "usageHistoryDailySnapshots"))

        shouldFailDailyEncoding = true
        let failedResult = makeHistoryResult(
            accountID: firstResult.accountID,
            fetchedAt: firstDate.addingTimeInterval(60 * 60),
            used: 40
        )
        store.record(results: [failedResult], now: failedResult.fetchedAt)

        XCTAssertEqual(store.snapshots, previousSnapshots)
        XCTAssertEqual(store.dailySnapshots, previousDailySnapshots)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), previousData)
        XCTAssertEqual(defaults.data(forKey: "usageHistoryDailySnapshots"), previousDailyData)
        XCTAssertTrue(store.lastError?.hasPrefix("Could not save usage history:") == true)
    }

    @MainActor
    func testUsageHistoryStoreRollsBackMissingAccountRemovalWhenEncodingFails() throws {
        let suiteName = "CodexBarMacTests.HistoryRemovalEncoding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var shouldFailEncoding = false
        let store = UsageHistoryStore(defaults: defaults) { snapshots in
            if shouldFailEncoding {
                throw CocoaError(.fileWriteUnknown)
            }
            return try JSONEncoder().encode(snapshots)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        store.record(
            results: [
                ProviderUsageResult(
                    accountID: "keep",
                    providerID: .codex,
                    title: "Keep",
                    subtitle: "Live",
                    bars: [UsageBar(label: "5h", used: 10, limit: 100)],
                    fetchedAt: fetchedAt
                ),
                ProviderUsageResult(
                    accountID: "drop",
                    providerID: .claude,
                    title: "Drop",
                    subtitle: "Live",
                    bars: [UsageBar(label: "Session", used: 20, limit: 100)],
                    fetchedAt: fetchedAt
                ),
            ],
            now: fetchedAt
        )
        let previousSnapshots = store.snapshots
        let previousDailySnapshots = store.dailySnapshots
        let previousData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
        let previousDailyData = try XCTUnwrap(defaults.data(forKey: "usageHistoryDailySnapshots"))

        shouldFailEncoding = true
        store.removeSnapshotsForMissingAccounts(validAccountIDs: ["keep"], now: fetchedAt)

        XCTAssertEqual(store.snapshots, previousSnapshots)
        XCTAssertEqual(store.dailySnapshots, previousDailySnapshots)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), previousData)
        XCTAssertEqual(defaults.data(forKey: "usageHistoryDailySnapshots"), previousDailyData)
        XCTAssertTrue(store.lastError?.hasPrefix("Could not save usage history:") == true)
    }

    @MainActor
    func testProviderUsageCardHistoryVisibilityDoesNotDeleteSnapshots() {
        let suiteName = "CodexBarMacTests.HistoryVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 42, limit: 100)],
            fetchedAt: fetchedAt
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [result], now: fetchedAt)
        let historyOptions = store.historySeriesOptions(for: result)

        let hiddenCard = ProviderUsageCard(
            result: result,
            historyOptions: historyOptions,
            isHistoryEnabled: false
        )
        let visibleCard = ProviderUsageCard(
            result: result,
            historyOptions: historyOptions,
            isHistoryEnabled: true
        )

        XCTAssertFalse(hiddenCard.showsHistory)
        XCTAssertTrue(visibleCard.showsHistory)
        XCTAssertFalse(historyOptions.isEmpty)
        XCTAssertEqual(store.snapshots.count, 1)
    }

    @MainActor
    func testUsageHistoryStorePrunesRetentionAndPerAccountLimit() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = UsageHistoryStore(defaults: defaults, retentionDays: 7, maxSnapshotsPerAccount: 2)

        let old = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 10, limit: 100)],
            fetchedAt: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        let first = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 20, limit: 100)],
            fetchedAt: now.addingTimeInterval(-3 * 60 * 60)
        )
        let second = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 30, limit: 100)],
            fetchedAt: now.addingTimeInterval(-2 * 60 * 60)
        )
        let third = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: 40, limit: 100)],
            fetchedAt: now.addingTimeInterval(-1 * 60 * 60)
        )

        store.record(results: [old, first, second, third], now: now)

        XCTAssertEqual(store.snapshots.count, 2)
        XCTAssertEqual(store.snapshots.compactMap { $0.bars.first?.used }, [30, 40])
    }

    @MainActor
    func testUsageHistoryStoreUpdatesDailyPointInsideDenseSamplingInterval() {
        let suiteName = "CodexBarMacTests.HistoryDailyReplacement.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let latestFetch = firstFetch.addingTimeInterval(60 * 60)
        let firstResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: firstFetch,
            used: 20
        )
        let latestResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: latestFetch,
            used: 35
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [firstResult], now: firstFetch, samplingInterval: 2 * 60 * 60)
        store.record(results: [latestResult], now: latestFetch, samplingInterval: 2 * 60 * 60)

        XCTAssertEqual(store.snapshots.compactMap { $0.bars.first?.used }, [20])
        XCTAssertEqual(store.dailySnapshots.compactMap { $0.bars.first?.used }, [35])
        XCTAssertEqual(store.historySeries(for: latestResult).points.map(\.value), [0.2, 0.35])

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.dailySnapshots.count, 1)
        XCTAssertEqual(reloadedStore.dailySnapshots.first?.capturedAt, latestFetch)
    }

    @MainActor
    func testDailyHistoryPreservesAbsentPartialRefreshComponentsAndMonetaryIdentities() throws {
        let suiteName = "CodexBarMacTests.HistoryDailyComponents.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = try XCTUnwrap(
            Calendar.autoupdatingCurrent.date(
                from: DateComponents(year: 2026, month: 9, day: 3, hour: 12)
            )
        )
        let fullResult = ProviderUsageResult(
            accountID: "opencode.personal",
            providerID: .openCodeZen,
            title: "OpenCode",
            subtitle: "Usage and balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 20, limit: 100)],
            creditsRemaining: 12,
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Spent",
                    minorUnits: 1_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .balance,
                    label: "Balance",
                    minorUnits: 2_000,
                    currencyCode: "EUR",
                    decimalPlaces: 2
                ),
            ],
            fetchedAt: firstFetch
        )
        let partialFetch = firstFetch.addingTimeInterval(3 * 60 * 60)
        let partialResult = ProviderUsageResult(
            accountID: fullResult.accountID,
            providerID: fullResult.providerID,
            title: fullResult.title,
            subtitle: "Fresh usage only",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage", used: 40, limit: 100)],
            creditsRemaining: 12,
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Spent",
                    minorUnits: 1_500,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            historyFreshness: ProviderUsageHistoryFreshness(
                bars: true,
                credits: false,
                monetaryMetrics: true
            ),
            isIncompleteRefresh: true,
            fetchedAt: partialFetch
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [fullResult], now: firstFetch, samplingInterval: 2 * 60 * 60)
        store.record(results: [partialResult], now: partialFetch, samplingInterval: 2 * 60 * 60)
        let denseSnapshots = store.snapshots(for: fullResult.accountID)
        XCTAssertEqual(denseSnapshots.count, 2)
        XCTAssertEqual(denseSnapshots[0].creditsRemaining, 12)
        XCTAssertEqual(denseSnapshots[1].bars.first?.used, 40)
        XCTAssertNil(denseSnapshots[1].creditsRemaining)
        XCTAssertEqual(denseSnapshots[1].monetaryMetrics?.first?.minorUnits, 1_500)
        XCTAssertEqual(store.dailySnapshots.compactMap(\.creditsRemaining), [12])
        store.removeSnapshotsForMissingAccounts(
            validAccountIDs: [fullResult.accountID],
            now: firstFetch.addingTimeInterval(31 * 24 * 60 * 60)
        )

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(store.dailySnapshots.count, 4)
        XCTAssertEqual(store.dailySnapshots.compactMap { $0.bars.first?.used }, [40])
        XCTAssertEqual(store.dailySnapshots.compactMap(\.creditsRemaining), [12])
        let monetary = store.dailySnapshots.compactMap { $0.monetaryMetrics?.first }
        XCTAssertEqual(Set(monetary.map { "\($0.kind.rawValue).\($0.currencyCode)" }), [
            "spent.USD",
            "balance.EUR",
        ])
        XCTAssertEqual(monetary.first(where: { $0.kind == .spent })?.minorUnits, 1_500)
        XCTAssertEqual(monetary.first(where: { $0.kind == .balance })?.minorUnits, 2_000)
    }

    @MainActor
    func testDailyHistoryReplacesLegacyCursorBucketsWithSemanticBuckets() {
        let suiteName = "CodexBarMacTests.HistoryDailyBars.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstFetch = Date(timeIntervalSince1970: 1_788_475_200)
        let firstResult = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Initial metrics",
            bars: [
                UsageBar(stableKey: "total", label: "Total", used: 20, limit: 100),
                UsageBar(label: "Auto", used: 30, limit: 100),
                UsageBar(label: "API", used: 50, limit: 100),
            ],
            fetchedAt: firstFetch
        )
        let latestFetch = firstFetch.addingTimeInterval(60 * 60)
        let partialResult = ProviderUsageResult(
            accountID: firstResult.accountID,
            providerID: firstResult.providerID,
            title: firstResult.title,
            subtitle: "Updated metrics",
            bars: [
                UsageBar(stableKey: "cursor-models", label: "Cursor Models", used: 40, limit: 100),
                UsageBar(stableKey: "other-models", label: "Other Models", used: 80, limit: 100),
            ],
            isIncompleteRefresh: true,
            fetchedAt: latestFetch
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [firstResult], now: firstFetch, samplingInterval: 2 * 60 * 60)
        store.record(results: [partialResult], now: latestFetch, samplingInterval: 2 * 60 * 60)

        XCTAssertEqual(Set(store.dailySnapshots.compactMap { $0.bars.first?.stableKey }), [
            "total",
            "cursor-models",
            "other-models",
        ])
        XCTAssertEqual(
            store.dailySnapshots.first(where: { $0.bars.first?.stableKey == "cursor-models" })?
                .bars.first?.used,
            40
        )
        let currentResult = ProviderUsageResult(
            accountID: firstResult.accountID,
            providerID: firstResult.providerID,
            title: firstResult.title,
            subtitle: "Current",
            bars: [],
            fetchedAt: latestFetch
        )
        let options = store.historySeriesOptions(for: currentResult)
        XCTAssertEqual(options.first(where: { $0.id == "usage.total" })?.series.points.map(\.value), [0.2])
        XCTAssertEqual(options.first(where: { $0.id == "usage.cursor-models" })?.series.points.map(\.value), [
            0.3,
            0.4,
        ])
        XCTAssertEqual(options.first(where: { $0.id == "usage.other-models" })?.series.points.map(\.value), [
            0.5,
            0.8,
        ])
        XCTAssertEqual(store.historySeries(for: currentResult).points.map(\.value), [0.2, 0.8])
    }

    @MainActor
    func testDailyHistoryIsolatesMatchingComponentsByAccount() {
        let suiteName = "CodexBarMacTests.HistoryDailyAccounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)

        store.record(
            results: [
                makeHistoryResult(accountID: "codex.personal", fetchedAt: fetchedAt, used: 20),
                makeHistoryResult(accountID: "codex.work", fetchedAt: fetchedAt, used: 70),
            ],
            now: fetchedAt
        )

        XCTAssertEqual(store.dailySnapshots.count, 2)
        XCTAssertEqual(
            store.historySeries(
                for: makeHistoryResult(
                    accountID: "codex.personal",
                    fetchedAt: fetchedAt,
                    used: 20
                )
            ).points.map(\.value),
            [0.2]
        )
        XCTAssertEqual(
            store.historySeries(
                for: makeHistoryResult(
                    accountID: "codex.work",
                    fetchedAt: fetchedAt,
                    used: 70
                )
            ).points.map(\.value),
            [0.7]
        )
    }

    @MainActor
    func testUsageHistoryStoreKeepsNinetyDailyPointsBeyondDenseRetention() throws {
        let suiteName = "CodexBarMacTests.HistoryDailyRetention.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 12))
        )
        let store = UsageHistoryStore(defaults: defaults)

        for daysAgo in (0..<95).reversed() {
            let fetchedAt = try XCTUnwrap(calendar.date(byAdding: .day, value: -daysAgo, to: now))
            store.record(
                results: [
                    makeHistoryResult(
                        accountID: "codex.personal",
                        fetchedAt: fetchedAt,
                        used: Double(daysAgo)
                    ),
                ],
                now: now,
                samplingInterval: 2 * 60 * 60
            )
        }

        XCTAssertEqual(store.dailySnapshots.count, 90)
        XCTAssertEqual(store.snapshots.count, 31)
        let reloadedStore = UsageHistoryStore(defaults: defaults)
        let currentResult = makeHistoryResult(
            accountID: "codex.personal",
            fetchedAt: now,
            used: 0
        )
        let series = reloadedStore.historySeries(for: currentResult)
        XCTAssertEqual(series.points.count, 90)
        XCTAssertEqual(
            series.points.first?.capturedAt,
            calendar.date(byAdding: .day, value: -89, to: now)
        )
    }

    func testUsageHistoryRangesUseInclusiveLocalCalendarDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 20))
        )
        let offsets = [0, -2, -3, -6, -7, -29, -30, -89, -90]
        let points = try offsets.enumerated().map { index, offset in
            UsageHistoryPoint(
                id: "point-\(index)",
                capturedAt: try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: now)),
                value: Double(index),
                severity: .normal
            )
        }
        let series = UsageHistorySeries(
            accountID: "codex.personal",
            points: points,
            isBalance: false
        )

        XCTAssertEqual(series.filtered(to: .today, now: now, calendar: calendar).points.count, 1)
        XCTAssertEqual(series.filtered(to: .threeDays, now: now, calendar: calendar).points.count, 2)
        XCTAssertEqual(series.filtered(to: .sevenDays, now: now, calendar: calendar).points.count, 4)
        XCTAssertEqual(series.filtered(to: .month, now: now, calendar: calendar).points.count, 6)
        XCTAssertEqual(series.filtered(to: .threeMonths, now: now, calendar: calendar).points.count, 8)
    }

    @MainActor
    func testUsageHistoryStorePreservesRecentDetailAndLongRangeCoverage() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let retention: TimeInterval = 30 * 24 * 60 * 60
        let cutoff = now.addingTimeInterval(-retention)
        let intervals = AutoRefreshInterval.allCases.compactMap(\.seconds)

        for interval in intervals {
            let suiteName = "CodexBarMacTests.HistoryRange.\(Int(interval)).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let sampleCount = Int(retention / interval)
            let results = (0...sampleCount).map { index in
                ProviderUsageResult(
                    accountID: "codex.personal",
                    providerID: .codex,
                    title: "Codex",
                    subtitle: "Live Codex usage",
                    bars: [UsageBar(label: "5h limit", used: Double(index % 100), limit: 100)],
                    fetchedAt: cutoff.addingTimeInterval(Double(index) * interval)
                )
            }
            let store = UsageHistoryStore(defaults: defaults)

            store.record(results: results, now: now)

            let retained = store.snapshots(for: "codex.personal")
            XCTAssertEqual(retained.count, 240, "Interval: \(interval)")
            XCTAssertEqual(retained.last?.capturedAt, now, "Interval: \(interval)")
            XCTAssertEqual(retained.first?.capturedAt, cutoff, "Interval: \(interval)")
            XCTAssertEqual(
                retained.suffix(120).map(\.capturedAt),
                results.suffix(120).map(\.fetchedAt),
                "Interval: \(interval)"
            )
            XCTAssertEqual(Set(retained.map(\.id)).count, retained.count, "Interval: \(interval)")

            let originalIDs = retained.map(\.id)
            store.removeSnapshotsForMissingAccounts(validAccountIDs: ["codex.personal"], now: now)
            XCTAssertEqual(store.snapshots(for: "codex.personal").map(\.id), originalIDs)
            XCTAssertTrue(store.snapshots.allSatisfy { $0.capturedAt >= cutoff })
        }
    }

    @MainActor
    func testUsageHistoryStoreDownsamplesAccountsIndependently() {
        let suiteName = "CodexBarMacTests.HistoryAccounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let interval: TimeInterval = 60 * 60
        let sampleCount = 30 * 24
        let results = ["codex.personal", "claude.work"].flatMap { accountID in
            (0...sampleCount).map { index in
                ProviderUsageResult(
                    accountID: accountID,
                    providerID: accountID == "codex.personal" ? .codex : .claude,
                    title: accountID,
                    subtitle: "Live usage",
                    bars: [UsageBar(label: "Usage", used: Double(index % 100), limit: 100)],
                    fetchedAt: now.addingTimeInterval(Double(index - sampleCount) * interval)
                )
            }
        }
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: results, now: now)

        for accountID in ["codex.personal", "claude.work"] {
            let retained = store.snapshots(for: accountID)
            XCTAssertEqual(retained.count, 240)
            XCTAssertEqual(retained.first?.capturedAt, now.addingTimeInterval(-30 * 24 * 60 * 60))
            XCTAssertEqual(retained.last?.capturedAt, now)
            XCTAssertEqual(
                retained.suffix(120).map(\.capturedAt),
                results.filter { $0.accountID == accountID }.suffix(120).map(\.fetchedAt)
            )
        }
    }

    @MainActor
    func testUsageHistoryStoreRemovesDeletedAccounts() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        store.record(
            results: [
                ProviderUsageResult(
                    accountID: "keep",
                    providerID: .codex,
                    title: "Keep",
                    subtitle: "Live",
                    bars: [UsageBar(label: "5h", used: 10, limit: 100)],
                    fetchedAt: fetchedAt
                ),
                ProviderUsageResult(
                    accountID: "drop",
                    providerID: .claude,
                    title: "Drop",
                    subtitle: "Live",
                    bars: [UsageBar(label: "Session", used: 20, limit: 100)],
                    fetchedAt: fetchedAt
                ),
            ],
            now: fetchedAt
        )

        store.removeSnapshotsForMissingAccounts(validAccountIDs: ["keep"], now: fetchedAt)

        XCTAssertEqual(store.snapshots.map(\.accountID), ["keep"])
        XCTAssertEqual(store.dailySnapshots.map(\.accountID), ["keep"])
        XCTAssertEqual(
            UsageHistoryStore(defaults: defaults).dailySnapshots.map(\.accountID),
            ["keep"]
        )
    }

    @MainActor
    func testUsageHistoryStoreSkipsEmptyProviderStates() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageHistoryStore(defaults: defaults)
        store.record(
            results: [
                ProviderUsageResult(
                    accountID: "empty",
                    providerID: .codex,
                    title: "Codex",
                    subtitle: "Waiting",
                    bars: [],
                    fetchedAt: Date(timeIntervalSince1970: 1_788_475_200)
                ),
            ]
        )

        XCTAssertTrue(store.snapshots.isEmpty)
    }

    @MainActor
    func testUsageHistoryStoreBuildsUsageAndBalanceSeries() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageHistoryStore(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_788_475_200)
        let t1 = t0.addingTimeInterval(3_600)

        let first = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live",
            bars: [UsageBar(label: "5h", used: 20, limit: 100)],
            fetchedAt: t0
        )
        let second = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live",
            bars: [UsageBar(label: "5h", used: 45, limit: 100)],
            fetchedAt: t1
        )
        store.record(results: [first, second], now: t1)

        let series = store.historySeries(for: second)
        XCTAssertFalse(series.isBalance)
        XCTAssertEqual(series.points.map(\.value), [0.2, 0.45])
        XCTAssertEqual(series.changeDescription, "Up 25 pts")
        XCTAssertEqual(series.minimumValueDescription, "20%")
        XCTAssertEqual(series.maximumValueDescription, "45%")

        let balance = ProviderUsageResult(
            accountID: "openrouter",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credits",
            bars: [],
            creditsRemaining: 12.5,
            fetchedAt: t0
        )
        let balanceLater = ProviderUsageResult(
            accountID: "openrouter",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credits",
            bars: [],
            creditsRemaining: 10.0,
            fetchedAt: t1
        )
        store.record(results: [balance, balanceLater], now: t1)
        let balanceSeries = store.historySeries(for: balanceLater)
        XCTAssertTrue(balanceSeries.isBalance)
        XCTAssertEqual(balanceSeries.points.map(\.value), [12.5, 10.0])
        XCTAssertEqual(balanceSeries.direction, .down)
    }

    @MainActor
    func testPercentageChartDomainExpandsPastHighestOverLimitValue() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let store = UsageHistoryStore(defaults: defaults)
        let samples = [
            ProviderUsageResult(
                accountID: "copilot.organization",
                providerID: .copilot,
                title: "GitHub Copilot",
                subtitle: "Organization usage",
                bars: [UsageBar(label: "AI credits", used: 80, limit: 100)],
                fetchedAt: now.addingTimeInterval(-60)
            ),
            ProviderUsageResult(
                accountID: "copilot.organization",
                providerID: .copilot,
                title: "GitHub Copilot",
                subtitle: "Organization usage",
                bars: [UsageBar(label: "AI credits", used: 125, limit: 100)],
                fetchedAt: now
            ),
        ]

        for sample in samples {
            store.record(results: [sample], now: now)
        }

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        let series = reloadedStore.historySeries(for: samples[1])

        XCTAssertEqual(reloadedStore.snapshots.last?.bars.first?.fractionUsed, 1)
        XCTAssertEqual(series.points.map(\.value), [0.8, 1.25])
        XCTAssertEqual(series.chartDomain.lowerBound, 0)
        XCTAssertGreaterThan(series.chartDomain.upperBound, 1.25)
        XCTAssertEqual(series.latestValueDescription, "125%")
        XCTAssertEqual(series.maximumValueDescription, "125%")
        XCTAssertEqual(series.rangeDescription, "Range 80% to 125%")
    }

    func testPercentageChartDomainStaysAtOneHundredPercentAtOrBelowLimit() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let series = UsageHistorySeries(
            accountID: "copilot.organization",
            points: [
                UsageHistoryPoint(
                    id: "under",
                    capturedAt: now.addingTimeInterval(-60),
                    value: 0.8,
                    severity: .normal
                ),
                UsageHistoryPoint(
                    id: "limit",
                    capturedAt: now,
                    value: 1,
                    severity: .critical
                ),
            ],
            isBalance: false
        )

        XCTAssertEqual(series.chartDomain, 0...1)
        XCTAssertEqual(series.latestValueDescription, "100%")
    }

    func testPercentageChartDomainPadsSmallOveragesWithoutLargeRescalingJump() {
        let series = UsageHistorySeries(
            accountID: "copilot.organization",
            points: [
                UsageHistoryPoint(
                    id: "barely-over",
                    capturedAt: Date(timeIntervalSince1970: 1_788_475_200),
                    value: 1.01,
                    severity: .critical
                ),
            ],
            isBalance: false
        )

        XCTAssertEqual(series.chartDomain.lowerBound, 0)
        XCTAssertEqual(series.chartDomain.upperBound, 1.02, accuracy: 0.0001)
    }

    func testUsageHistoryBarSnapshotDecodesLegacyLabelOnlyData() throws {
        let data = Data(
            #"{"label":"Total","fractionUsed":1,"used":125,"limit":100}"#.utf8
        )

        let snapshot = try JSONDecoder().decode(UsageHistoryBarSnapshot.self, from: data)

        XCTAssertNil(snapshot.stableKey)
        XCTAssertEqual(snapshot.label, "Total")
        XCTAssertEqual(snapshot.fractionUsed, 1)
        XCTAssertEqual(snapshot.historyFractionUsed, 1.25)
        XCTAssertEqual(snapshot.effectiveSeverity, .critical)
    }

    @MainActor
    func testCursorHistoryPreservesLegacyTotalAndMapsLegacyModelBuckets() throws {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let legacyResult = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Legacy",
            bars: [
                UsageBar(stableKey: "total", label: "Total", used: 125, limit: 100),
                UsageBar(stableKey: "auto", label: "Auto", used: 29, limit: 100),
                UsageBar(stableKey: "api", label: "API", used: 150, limit: 100),
                UsageBar(
                    stableKey: "on-demand",
                    label: "On-demand $0.00 / $20.00",
                    used: 0,
                    limit: 20
                ),
                UsageBar(stableKey: "grok-bot-weekly", label: "Grok Bot weekly", used: 38, limit: 100),
            ],
            fetchedAt: fetchedAt
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [legacyResult], now: fetchedAt)

        let currentResult = ProviderUsageResult(
            accountID: legacyResult.accountID,
            providerID: legacyResult.providerID,
            title: legacyResult.title,
            subtitle: "Current",
            bars: [
                UsageBar(stableKey: "cursor-models", label: "Cursor Models", used: 29, limit: 100),
                UsageBar(stableKey: "other-models", label: "Other Models", used: 100, limit: 100),
                UsageBar(
                    stableKey: "on-demand",
                    label: "On-demand $0.00 / $20.00",
                    used: 0,
                    limit: 20
                ),
                UsageBar(stableKey: "grok-bot-weekly", label: "Grok Bot weekly", used: 38, limit: 100),
            ],
            fetchedAt: fetchedAt.addingTimeInterval(60)
        )

        let snapshot = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(snapshot.bars.map(\.stableKey), ["total", "auto", "api", "on-demand", "grok-bot-weekly"])
        XCTAssertEqual(snapshot.primaryValue, 1.25)
        XCTAssertEqual(store.historySeries(for: currentResult).points.map(\.value), [1.25, 1])
        XCTAssertEqual(store.historySeries(for: currentResult).points.map(\.severity), [.critical, .critical])

        let options = store.historySeriesOptions(for: currentResult)
        XCTAssertEqual(options.map(\.id), [
            "usage",
            "usage.total",
            "usage.cursor-models",
            "usage.other-models",
            "usage.on-demand",
            "usage.grok-bot-weekly",
        ])
        XCTAssertEqual(
            options.map(\.label),
            [
                "Total / highest available",
                "Total",
                "Cursor Models",
                "Other Models",
                "On-demand",
                "Grok Bot weekly",
            ]
        )
        XCTAssertEqual(options.map { $0.series.points.map(\.value) }, [
            [1.25, 1],
            [1.25],
            [0.29, 0.29],
            [1.5, 1],
            [0, 0],
            [0.38, 0.38],
        ])
    }

    @MainActor
    func testCursorSpendLimitHistoryPreservesCriticalSeverityWithoutMonetaryMetrics() throws {
        let suiteName = "CodexBarMacTests.CursorSpendLimitHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let payload = Data(
            #"{"spendLimitUsage":{"individualLimit":2000,"individualRemaining":0}}"#.utf8
        )
        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            payload,
            configuration: .defaultConfiguration(for: .cursor),
            fetchedAt: fetchedAt
        ))
        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(result.hasReachedSpendLimit)
        XCTAssertTrue(result.historyFreshness.bars)
        XCTAssertFalse(result.historyFreshness.monetaryMetrics)
        XCTAssertTrue(result.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            result.bars.first(where: { $0.stableKey == "on-demand" })?.effectiveSeverity(at: fetchedAt),
            .critical
        )
        store.record(results: [result], now: fetchedAt)

        XCTAssertEqual(store.historySeries(for: result).points.map(\.severity), [.critical])
    }

    @MainActor
    func testCursorHistoryMapsLegacyLabelsConservatively() throws {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let legacyResult = ProviderUsageResult(
            accountID: "cursor.legacy",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Legacy",
            bars: [
                UsageBar(stableKey: "total", label: "Total", used: 38, limit: 100),
                UsageBar(stableKey: "auto", label: "Auto", used: 29, limit: 100),
                UsageBar(stableKey: "api", label: "API", used: 100, limit: 100),
                UsageBar(stableKey: "unknown", label: "Total-ish", used: 95, limit: 100),
                UsageBar(
                    stableKey: "on-demand",
                    label: "On-demand $0.00 / $20.00",
                    used: 0,
                    limit: 20
                ),
            ],
            fetchedAt: fetchedAt
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [legacyResult], now: fetchedAt)

        let encoded = try JSONEncoder().encode(store.snapshots)
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
        )
        var bars = try XCTUnwrap(payload[0]["bars"] as? [[String: Any]])
        for index in bars.indices {
            bars[index].removeValue(forKey: "stableKey")
            bars[index].removeValue(forKey: "effectiveSeverity")
        }
        payload[0]["bars"] = bars
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "usageHistorySnapshots")

        let reloadedStore = UsageHistoryStore(defaults: defaults)
        XCTAssertFalse(reloadedStore.requiresRecovery)
        let reloadedBars = try XCTUnwrap(reloadedStore.snapshots.first?.bars)
        XCTAssertTrue(reloadedBars.allSatisfy { $0.stableKey == nil })
        XCTAssertEqual(
            reloadedBars.first(where: { $0.label == "API" })?.effectiveSeverity,
            .critical
        )
        let currentResult = ProviderUsageResult(
            accountID: legacyResult.accountID,
            providerID: legacyResult.providerID,
            title: legacyResult.title,
            subtitle: "Current",
            bars: [
                UsageBar(stableKey: "cursor-models", label: "Cursor Models", used: 50, limit: 100),
                UsageBar(stableKey: "other-models", label: "Other Models", used: 20, limit: 100),
                UsageBar(stableKey: "on-demand", label: "On-demand", used: 0, limit: 20),
            ],
            fetchedAt: fetchedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(reloadedStore.historySeries(for: currentResult).points.map(\.value), [0.38, 0.5])

        let options = reloadedStore.historySeriesOptions(for: currentResult)
        XCTAssertEqual(options.map(\.id), [
            "usage",
            "usage.total",
            "usage.cursor-models",
            "usage.other-models",
            "usage.on-demand",
        ])
        XCTAssertNil(options.first(where: { $0.id == "usage.unknown" }))
        XCTAssertEqual(options.map { $0.series.points.map(\.value) }, [
            [0.38, 0.5],
            [0.38],
            [0.29, 0.5],
            [1, 0.2],
            [0, 0],
        ])
    }

    @MainActor
    func testUsageHistoryStoreBuildsSelectableSeriesOptions() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageHistoryStore(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_788_475_200)
        let t1 = t0.addingTimeInterval(3_600)
        let first = ProviderUsageResult(
            accountID: "claude.main",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [UsageBar(label: "Session", used: 20, limit: 100)],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 1_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                )
            ],
            fetchedAt: t0
        )
        let second = ProviderUsageResult(
            accountID: "claude.main",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [UsageBar(label: "Session", used: 35, limit: 100)],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 1_250,
                    currencyCode: "USD",
                    decimalPlaces: 2
                )
            ],
            fetchedAt: t1
        )
        store.record(results: [first, second], now: t1)

        let options = store.historySeriesOptions(for: second)

        XCTAssertEqual(options.map(\.label), ["Usage", "Usage credits spent"])
        XCTAssertEqual(options[0].series.points.map(\.value), [0.2, 0.35])
        XCTAssertEqual(options[1].series.points.map(\.value), [10.0, 12.5])
        XCTAssertFalse(options[1].series.isIncreaseFavorable)
        XCTAssertEqual(options[1].series.minimumValueDescription, "$10.00")
        XCTAssertEqual(options[1].series.maximumValueDescription, "$12.50")
    }

    @MainActor
    func testUsageHistoryStoreKeepsBalanceLikeSeriesPrimaryForMonetaryOnlyResult() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        func result(at date: Date, spent: Decimal, headroom: Decimal) -> ProviderUsageResult {
            ProviderUsageResult(
                accountID: "claude.main",
                providerID: .claude,
                title: "Claude",
                subtitle: "Live",
                bars: [],
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .spent,
                        label: "Usage credits spent",
                        minorUnits: spent,
                        currencyCode: "USD",
                        decimalPlaces: 2
                    ),
                    ProviderMonetaryMetric(
                        kind: .spendLimit,
                        label: "Monthly spend limit",
                        minorUnits: 10_000,
                        currencyCode: "USD",
                        decimalPlaces: 2
                    ),
                    ProviderMonetaryMetric(
                        kind: .remainingHeadroom,
                        label: "Remaining spend headroom",
                        minorUnits: headroom,
                        currencyCode: "USD",
                        decimalPlaces: 2
                    ),
                ],
                fetchedAt: date
            )
        }

        let t0 = Date(timeIntervalSince1970: 1_788_475_200)
        let t1 = t0.addingTimeInterval(3_600)
        let first = result(at: t0, spent: 1_000, headroom: 9_000)
        let second = result(at: t1, spent: 1_250, headroom: 8_750)
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [first, second], now: t1)

        let options = store.historySeriesOptions(for: second)

        XCTAssertEqual(
            options.map(\.label),
            ["Remaining spend headroom", "Usage credits spent", "Monthly spend limit"]
        )
        XCTAssertEqual(options[0].series.points.map(\.value), [90.0, 87.5])
        XCTAssertEqual(options[0].series.direction, .down)
    }

    @MainActor
    func testUsageHistoryStoreDoesNotMixHeadroomIntoBalanceSeries() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let t0 = Date(timeIntervalSince1970: 1_788_475_200)
        let t1 = t0.addingTimeInterval(3_600)
        let oldHeadroom = ProviderUsageResult(
            accountID: "claude.main",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 3_750,
                    currencyCode: "USD",
                    decimalPlaces: 2
                )
            ],
            fetchedAt: t0
        )
        let currentBalance = ProviderUsageResult(
            accountID: oldHeadroom.accountID,
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .balance,
                    label: "Current balance",
                    minorUnits: 10_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 2_500,
                    currencyCode: "USD",
                    decimalPlaces: 2
                )
            ],
            fetchedAt: t1
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [oldHeadroom, currentBalance], now: t1)

        let options = store.historySeriesOptions(for: currentBalance)

        XCTAssertEqual(options.map(\.label), ["Current balance", "Remaining spend headroom"])
        XCTAssertEqual(options[0].series.points.map(\.value), [100.0])
        XCTAssertEqual(options[0].series.currencyCode, "USD")
        XCTAssertEqual(options[1].series.points.map(\.value), [37.5, 25.0])
    }

    @MainActor
    func testUsageHistoryStoreKeepsHistoricalPrimaryAmongCurrentMonetaryOptions() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let t0 = Date(timeIntervalSince1970: 1_788_475_200)
        let t1 = t0.addingTimeInterval(3_600)
        let historicalHeadroom = ProviderUsageResult(
            accountID: "claude.main",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 3_750,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 1_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                )
            ],
            fetchedAt: t0
        )
        let currentSpent = ProviderUsageResult(
            accountID: historicalHeadroom.accountID,
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 1_250,
                    currencyCode: "USD",
                    decimalPlaces: 2
                )
            ],
            fetchedAt: t1
        )
        let store = UsageHistoryStore(defaults: defaults)
        store.record(results: [historicalHeadroom, currentSpent], now: t1)

        let options = store.historySeriesOptions(for: currentSpent)

        XCTAssertEqual(options.map(\.label), ["Remaining spend headroom", "Usage credits spent"])
        XCTAssertEqual(options[0].series.points.map(\.value), [37.5])
        XCTAssertEqual(options[1].series.points.map(\.value), [10.0, 12.5])
    }

    @MainActor
    func testUsageHistoryStoreRecordsClaudeMonetaryMetrics() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageHistoryStore(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_788_475_200)
        let t1 = t0.addingTimeInterval(3_600)
        let first = ProviderUsageResult(
            accountID: "claude.main",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 3_750,
                    currencyCode: "USD",
                    decimalPlaces: 2
                )
            ],
            fetchedAt: t0
        )
        let second = ProviderUsageResult(
            accountID: "claude.main",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: 2_500,
                    currencyCode: "USD",
                    decimalPlaces: 2
                )
            ],
            fetchedAt: t1
        )

        store.record(results: [first, second], now: t1)

        XCTAssertEqual(store.snapshots.count, 2)
        XCTAssertEqual(store.snapshots.first?.monetaryMetrics?.first?.kind, .remainingHeadroom)

        let series = store.historySeries(for: second)
        XCTAssertTrue(series.isBalance)
        XCTAssertEqual(series.currencyCode, "USD")
        XCTAssertEqual(series.points.count, 2)
        XCTAssertEqual(series.points[0].value, 37.5, accuracy: 0.0001)
        XCTAssertEqual(series.points[1].value, 25.0, accuracy: 0.0001)
    }

    @MainActor
    func testUsageHistoryStoreSkipsSpentOnlyMonetaryBalanceSeries() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageHistoryStore(defaults: defaults)
        let t0 = Date(timeIntervalSince1970: 1_788_475_200)
        let spentOnly = ProviderUsageResult(
            accountID: "claude.spent",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Usage credits spent",
                    minorUnits: 1_250,
                    currencyCode: "USD",
                    decimalPlaces: 2
                )
            ],
            fetchedAt: t0
        )

        store.record(results: [spentOnly], now: t0)

        XCTAssertEqual(store.snapshots.count, 1)
        let series = store.historySeries(for: spentOnly)
        XCTAssertFalse(series.isBalance)
        XCTAssertTrue(series.points.isEmpty)
    }

    private func makeHistoryResult(
        accountID: String,
        fetchedAt: Date,
        used: Double
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: accountID,
            providerID: .codex,
            title: accountID,
            subtitle: "Live Codex usage",
            bars: [UsageBar(label: "5h limit", used: used, limit: 100)],
            fetchedAt: fetchedAt
        )
    }
}
