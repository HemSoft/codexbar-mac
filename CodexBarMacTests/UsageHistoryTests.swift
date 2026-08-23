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
    func testUsageHistoryStoreTreatsAbsentStorageAsEmptyHistory() {
        let suiteName = "CodexBarMacTests.HistoryAbsent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertNil(store.lastError)
        XCTAssertFalse(store.requiresRecovery)
        XCTAssertNil(defaults.object(forKey: "usageHistorySnapshots"))
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

        let store = UsageHistoryStore(defaults: defaults)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.requiresRecovery)
        XCTAssertEqual(
            store.lastError,
            "Saved usage history could not be read. Reset history to resume recording."
        )

        store.record(results: [result], now: fetchedAt)
        store.removeSnapshotsForMissingAccounts(validAccountIDs: [result.accountID], now: fetchedAt)

        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), malformedData)
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(store.requiresRecovery)
        XCTAssertNotNil(store.lastError)

        store.discardCorruptedHistory()

        XCTAssertNil(defaults.object(forKey: "usageHistorySnapshots"))
        XCTAssertEqual(defaults.string(forKey: "unrelatedSetting"), "preserve-me")
        XCTAssertFalse(store.requiresRecovery)
        XCTAssertNil(store.lastError)

        store.record(results: [result], now: fetchedAt)

        XCTAssertEqual(store.snapshots.map(\.accountID), [result.accountID])
        XCTAssertNotNil(defaults.data(forKey: "usageHistorySnapshots"))
        XCTAssertNil(store.lastError)

        store.removeSnapshotsForMissingAccounts(validAccountIDs: [], now: fetchedAt)

        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertEqual(
            try JSONDecoder().decode(
                [UsageHistorySnapshot].self,
                from: try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))
            ),
            []
        )
        XCTAssertNil(store.lastError)
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
        let previousData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))

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
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), previousData)
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
        XCTAssertNotEqual(defaults.data(forKey: "usageHistorySnapshots"), previousData)
        XCTAssertEqual(UsageHistoryStore(defaults: defaults).snapshots, store.snapshots)
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
        let previousData = try XCTUnwrap(defaults.data(forKey: "usageHistorySnapshots"))

        shouldFailEncoding = true
        store.removeSnapshotsForMissingAccounts(validAccountIDs: ["keep"], now: fetchedAt)

        XCTAssertEqual(store.snapshots, previousSnapshots)
        XCTAssertEqual(defaults.data(forKey: "usageHistorySnapshots"), previousData)
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
    func testCursorHistoryUsesStableTotalAndExposesDistinctMetricSeries() throws {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Current",
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
            ],
            fetchedAt: fetchedAt
        )
        let store = UsageHistoryStore(defaults: defaults)

        store.record(results: [result], now: fetchedAt)

        let snapshot = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(snapshot.bars.map(\.stableKey), ["total", "auto", "api", "on-demand"])
        XCTAssertEqual(snapshot.primaryValue, 1.25)
        XCTAssertEqual(store.historySeries(for: result).points.map(\.value), [1.25])
        XCTAssertEqual(store.historySeries(for: result).points.map(\.severity), [.critical])

        let options = store.historySeriesOptions(for: result)
        XCTAssertEqual(options.map(\.id), [
            "usage.total",
            "usage.auto",
            "usage.api",
            "usage.on-demand",
        ])
        XCTAssertEqual(options.map(\.label), ["Total", "Auto", "API", "On-demand"])
        XCTAssertEqual(options.map { $0.series.points.map(\.value) }, [
            [1.25],
            [0.29],
            [1.5],
            [0],
        ])

        let reorderedAndRelabeledResult = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: [
                UsageBar(stableKey: "api", label: "API requests", used: 100, limit: 100),
                UsageBar(stableKey: "on-demand", label: "On-demand spend", used: 0, limit: 20),
                UsageBar(stableKey: "auto", label: "Included Auto", used: 29, limit: 100),
                UsageBar(stableKey: "total", label: "Overall plan", used: 38, limit: 100),
            ],
            fetchedAt: fetchedAt.addingTimeInterval(60)
        )

        XCTAssertEqual(
            store.historySeries(for: reorderedAndRelabeledResult).points.map(\.value),
            [1.25]
        )
        XCTAssertEqual(
            store.historySeriesOptions(for: reorderedAndRelabeledResult).map(\.id),
            options.map(\.id)
        )
    }

    @MainActor
    func testCursorHistoryMapsLegacyLabelsConservatively() throws {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fetchedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let result = ProviderUsageResult(
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
        store.record(results: [result], now: fetchedAt)

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
        XCTAssertEqual(reloadedStore.historySeries(for: result).points.map(\.value), [0.38])

        let options = reloadedStore.historySeriesOptions(for: result)
        XCTAssertEqual(options.map(\.id), [
            "usage.total",
            "usage.auto",
            "usage.api",
            "usage.on-demand",
        ])
        XCTAssertNil(options.first(where: { $0.id == "usage.unknown" }))
        XCTAssertEqual(options.map { $0.series.points.map(\.value) }, [
            [0.38],
            [0.29],
            [1],
            [0],
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
