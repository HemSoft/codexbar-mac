import XCTest
@testable import CodexBarMac

final class UsageAlertTests: XCTestCase {
    deinit {}

    @MainActor
    func testUsageAlertSettingsPersistAndClamp() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertFalse(store.usageAlertSettings.isEnabled)
        XCTAssertEqual(store.usageAlertSettings.usageThreshold, 0.80)
        XCTAssertEqual(store.usageAlertSettings.balanceThreshold, 5.00)

        store.updateUsageAlertsEnabled(true)
        store.updateUsageAlertUsageThreshold(1.8)
        store.updateUsageAlertBalanceThreshold(-5)
        store.updateUsageAlertIncludesSeverityAlerts(false)
        store.updateUsageAlertActiveIDs(["usage.codex.weekly", "balance.openRouter"])

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertTrue(reloadedStore.usageAlertSettings.isEnabled)
        XCTAssertEqual(reloadedStore.usageAlertSettings.usageThreshold, 1.0)
        XCTAssertEqual(reloadedStore.usageAlertSettings.balanceThreshold, 0)
        XCTAssertFalse(reloadedStore.usageAlertSettings.includesSeverityAlerts)
        XCTAssertEqual(reloadedStore.usageAlertActiveIDs, ["usage.codex.weekly", "balance.openRouter"])
    }

    @MainActor
    func testUsageAlertSettingsChangeClearsActiveSuppressionState() {
        let suiteName = "CodexBarMacTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        store.updateUsageAlertActiveIDs(["usage.codex.weekly"])
        store.updateUsageAlertUsageThreshold(0.90)

        XCTAssertTrue(store.usageAlertActiveIDs.isEmpty)
    }

    func testUsageAlertEvaluatorSendsOnceUntilRecovery() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    label: "5-hour",
                    used: 81,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            includesSeverityAlerts: false
        )

        let first = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])
        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.notifications.first?.title, "Codex 5-hour alert")
        XCTAssertEqual(first.notifications.first?.accountID, "codex.personal")
        XCTAssertEqual(first.notifications.first?.kind, .usage)
        XCTAssertEqual(first.notifications.first?.body, "5-hour at 81%. 81 of 100 used. Alert threshold: 80%.")
        XCTAssertEqual(first.activeAlerts.count, 1)
        XCTAssertEqual(first.activeAlerts.first?.accountID, "codex.personal")
        XCTAssertEqual(first.activeAlerts.first?.title, "5-hour at 81%")

        let repeated = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )
        XCTAssertTrue(repeated.notifications.isEmpty)
        XCTAssertEqual(repeated.activeAlerts, first.activeAlerts)

        let recoveredResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    label: "5-hour",
                    used: 40,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let recovered = UsageAlertEvaluator.evaluate(
            results: [recoveredResult],
            settings: settings,
            activeAlertIDs: repeated.activeAlertIDs
        )
        XCTAssertTrue(recovered.activeAlertIDs.isEmpty)

        let crossedAgain = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: recovered.activeAlertIDs
        )
        XCTAssertEqual(crossedAgain.notifications.count, 1)
    }

    func testUsageAlertEvaluatorUsesInjectedNowForResetDescription() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let resetAt = now.addingTimeInterval(2 * 60 * 60)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    label: "5-hour",
                    used: 81,
                    limit: 100,
                    resetDescription: "stale reset text",
                    resetsAt: resetAt,
                    resetDisplayStyle: .relativeWithLocalTime
                ),
            ],
            fetchedAt: now
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: [],
            now: now
        )

        let body = try XCTUnwrap(evaluation.notifications.first?.body)
        XCTAssertTrue(body.contains("Resets 2h 0m"))
        XCTAssertFalse(body.contains("stale reset text"))
    }

    func testUsageAlertEvaluatorUsesStableUsageKeysForMutableLabels() {
        let firstResult = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    stableKey: "on-demand",
                    label: "On-demand $12.00 / $20.00",
                    used: 12,
                    limit: 20
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let secondResult = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    stableKey: "on-demand",
                    label: "On-demand $14.00 / $20.00",
                    used: 14,
                    limit: 20
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let settings = UsageAlertSettings(isEnabled: true, usageThreshold: 0.50)

        let first = UsageAlertEvaluator.evaluate(results: [firstResult], settings: settings, activeAlertIDs: [])
        let repeated = UsageAlertEvaluator.evaluate(
            results: [secondResult],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.activeAlertIDs, ["usage.cursor.main.on-demand"])
        XCTAssertTrue(repeated.notifications.isEmpty)
        XCTAssertEqual(repeated.activeAlertIDs, ["usage.cursor.main.on-demand"])
    }

    func testUsageAlertEvaluatorDeduplicatesBarsWithSameStableKey() {
        let result = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(stableKey: "on-demand", label: "On-demand $12.00 / $20.00", used: 12, limit: 20),
                UsageBar(stableKey: "on-demand", label: "On-demand $18.00 / $30.00", used: 18, limit: 30),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.50,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.activeAlertIDs, ["usage.cursor.main.on-demand"])
    }

    func testUsageAlertEvaluatorReportsBalanceThreshold() {
        let result = ProviderUsageResult(
            accountID: "openRouter.main",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 4.50,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(isEnabled: true, balanceThreshold: 5)

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.notifications.first?.title, "OpenRouter balance alert")
        XCTAssertEqual(evaluation.notifications.first?.accountID, "openRouter.main")
        XCTAssertEqual(evaluation.notifications.first?.kind, .balance)
        XCTAssertTrue(evaluation.activeAlertIDs.contains("balance.openRouter.main"))
        XCTAssertEqual(evaluation.activeAlerts.first?.title, "Balance below $5.00")
        XCTAssertEqual(evaluation.activeAlerts.first?.message, "$4.50 remaining for OpenRouter.")
    }

    func testUsageAlertEvaluatorAlertsScopedClaudeBarsWithoutBalanceFalsePositive() {
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Fable weekly limit", used: 85, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: []
        )

        XCTAssertEqual(evaluation.notifications.map(\.kind), [.usage])
        XCTAssertEqual(evaluation.notifications.first?.title, "Claude Fable weekly limit alert")
        XCTAssertFalse(evaluation.activeAlertIDs.contains("balance.claude.personal"))
    }

    func testUsageAlertEvaluatorReturnsCardScopedActiveAlerts() {
        let codex = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Weekly", used: 90, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let cursor = ProviderUsageResult(
            accountID: "cursor.work",
            providerID: .cursor,
            title: "Cursor Work",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Included", used: 40, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let openRouter = ProviderUsageResult(
            accountID: "openRouter.main",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 2,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [codex, cursor, openRouter],
            settings: settings,
            activeAlertIDs: []
        )
        let activeAlertsByAccountID = Dictionary(grouping: evaluation.activeAlerts, by: \.accountID)

        XCTAssertEqual(Set(activeAlertsByAccountID.keys), ["codex.personal", "openRouter.main"])
        XCTAssertEqual(activeAlertsByAccountID["codex.personal"]?.map(\.kind), [.usage])
        XCTAssertEqual(activeAlertsByAccountID["openRouter.main"]?.map(\.kind), [.balance])
        XCTAssertNil(activeAlertsByAccountID["cursor.work"])
    }

    @MainActor
    func testAppModelReturnsCurrentUsageAlertsByAccountID() {
        let suiteName = "CodexBarMacTests.ActiveAlerts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let result = ProviderUsageResult(
            accountID: "openRouter",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 2,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        configurationStore.seedDefaultConfigurationsIfNeeded()
        configurationStore.updateUsageAlertsEnabled(true)
        configurationStore.updateUsageAlertUsageThreshold(0.80)
        configurationStore.updateUsageAlertIncludesSeverityAlerts(false)
        var configuration = configurationStore.configuration(for: .openRouter)
        configuration.accountLabel = "Research"
        XCTAssertTrue(configurationStore.update(configuration))
        let refreshService = UsageRefreshService(providers: [], initialResults: [result])
        XCTAssertEqual(refreshService.successfulRefreshResults.map(\.accountID), ["openRouter"])
        let model = AppModel(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: UsageHistoryStore(defaults: defaults),
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        XCTAssertEqual(model.currentUsageAlertsByAccountID["openRouter"]?.map(\.kind), [.balance])
        XCTAssertEqual(
            model.currentUsageAlertsByAccountID["openRouter"]?.first?.message,
            "$2.00 remaining for Research."
        )

        configurationStore.updateUsageAlertsEnabled(false)

        XCTAssertTrue(model.currentUsageAlertsByAccountID.isEmpty)
    }

    @MainActor
    func testProviderUsageCardActiveAlertRaisesCardSeverity() {
        let result = ProviderUsageResult(
            accountID: "openRouter",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 20,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let alert = UsageAlertDetail(
            id: "balance.openRouter",
            accountID: "openRouter",
            kind: .balance,
            title: "Balance below $25.00",
            message: "$20.00 remaining for OpenRouter.",
            severity: .warning
        )
        let card = ProviderUsageCard(
            result: result,
            historyOptions: [],
            alerts: [alert],
            isHistoryEnabled: false
        )

        XCTAssertEqual(card.alerts, [alert])
        XCTAssertEqual(card.cardSeverity, .warning)
    }

    @MainActor
    func testCodexCardHidesOnlyUsageThresholdAlerts() {
        let usageAlert = UsageAlertDetail(
            id: "usage.codex.personal.weekly",
            accountID: "codex.personal",
            kind: .usage,
            title: "Weekly at 92%",
            message: "92 of 100 used. Alert threshold: 80%.",
            severity: .warning
        )
        let balanceAlert = UsageAlertDetail(
            id: "balance.codex.personal",
            accountID: "codex.personal",
            kind: .balance,
            title: "Balance below $5.00",
            message: "$4.50 remaining for Codex.",
            severity: .warning
        )
        let severityAlert = UsageAlertDetail(
            id: "severity.codex.personal",
            accountID: "codex.personal",
            kind: .severity,
            title: "Critical status",
            message: "Weekly is projected to reach 100%.",
            severity: .critical
        )
        let codexResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 92, limit: 100)],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let codexCard = ProviderUsageCard(
            result: codexResult,
            historyOptions: [],
            alerts: [usageAlert, balanceAlert, severityAlert],
            isHistoryEnabled: false
        )

        XCTAssertEqual(codexCard.displayedAlerts, [balanceAlert, severityAlert])
        XCTAssertEqual(codexCard.hiddenAlerts, [usageAlert])
        XCTAssertTrue(codexCard.showsAlertSummary)
        XCTAssertEqual(codexCard.alerts, [usageAlert, balanceAlert, severityAlert])
        XCTAssertEqual(codexCard.cardSeverity, .critical)
        XCTAssertEqual(
            codexCard.hiddenAlertAccessibilityLabel,
            "\(usageAlert.title). \(usageAlert.message)"
        )

        let usageOnlyCodexCard = ProviderUsageCard(
            result: codexResult,
            historyOptions: [],
            alerts: [usageAlert],
            isHistoryEnabled: false
        )

        XCTAssertTrue(usageOnlyCodexCard.displayedAlerts.isEmpty)
        XCTAssertFalse(usageOnlyCodexCard.showsAlertSummary)
        XCTAssertEqual(usageOnlyCodexCard.hiddenAlerts, [usageAlert])
        XCTAssertEqual(
            usageOnlyCodexCard.hiddenAlertAccessibilityLabel,
            "\(usageAlert.title). \(usageAlert.message)"
        )

        let cursorResult = ProviderUsageResult(
            accountID: "cursor.personal",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [UsageBar(label: "Total", used: 92, limit: 100)],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let cursorCard = ProviderUsageCard(
            result: cursorResult,
            historyOptions: [],
            alerts: [usageAlert, balanceAlert, severityAlert],
            isHistoryEnabled: false
        )

        XCTAssertEqual(cursorCard.displayedAlerts, [usageAlert, balanceAlert, severityAlert])
        XCTAssertTrue(cursorCard.hiddenAlerts.isEmpty)
        XCTAssertTrue(cursorCard.hiddenAlertAccessibilityLabel.isEmpty)
        XCTAssertTrue(cursorCard.showsAlertSummary)
    }

    func testUsageAlertEvaluatorPreservesSuppressionForExactAccountsThatDidNotRefresh() {
        let activeAlertIDs: Set<String> = [
            "usage.codex.weekly",
            "usage.codex.secondary.weekly",
            "balance.openrouter.failed",
        ]

        let preserved = UsageAlertEvaluator.activeAlertIDs(
            activeAlertIDs,
            belongingTo: ["codex.secondary", "openrouter.failed"],
            knownAccountIDs: ["codex", "codex.secondary", "openrouter.failed"]
        )

        XCTAssertEqual(
            preserved,
            ["usage.codex.secondary.weekly", "balance.openrouter.failed"]
        )
    }

    func testUsageAlertEvaluatorClearsSuppressionWhenNoAccountsArePreserved() {
        let preserved = UsageAlertEvaluator.activeAlertIDs(
            ["usage.codex.weekly"],
            belongingTo: [],
            knownAccountIDs: ["codex"]
        )

        XCTAssertTrue(preserved.isEmpty)
    }

    func testUsageAlertEvaluatorUsesSeverityWhenSpecificThresholdsDoNotMatch() {
        let result = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Included usage - Total 76%",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    label: "Total",
                    used: 76,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.90,
            balanceThreshold: 5,
            includesSeverityAlerts: true
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.notifications.first?.title, "Cursor Warning alert")
        XCTAssertTrue(evaluation.activeAlertIDs.contains("severity.cursor.main.1"))
        XCTAssertEqual(
            evaluation.notifications.first?.body,
            "Cursor: Warning status. Total current usage is 76% (Warning threshold: 75%)."
        )
        XCTAssertEqual(
            evaluation.activeAlerts.first?.message,
            "Total current usage is 76% (Warning threshold: 75%)."
        )
    }

    func testUsageAlertNotificationsIdentifyCustomAndFallbackLabelsForSameProvider() {
        let results = [
            ProviderUsageResult(
                accountID: "codex.first-private-id",
                providerID: .codex,
                title: "Work Codex",
                subtitle: "Live usage",
                bars: [UsageBar(label: "Weekly", used: 80, limit: 100)],
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            ),
            ProviderUsageResult(
                accountID: "codex.second-private-id",
                providerID: .codex,
                title: "ChatGPT / Codex",
                subtitle: "Live usage",
                bars: [UsageBar(label: "Weekly", used: 80, limit: 100)],
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            ),
            ProviderUsageResult(
                accountID: "codex.third-private-id",
                providerID: .codex,
                title: "ChatGPT / Codex 2",
                subtitle: "Live usage",
                bars: [UsageBar(label: "Weekly", used: 80, limit: 100)],
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            ),
        ]

        let evaluations = results.map {
            UsageAlertEvaluator.evaluate(
                results: [$0],
                settings: UsageAlertSettings(
                    isEnabled: true,
                    usageThreshold: 1,
                    includesSeverityAlerts: true
                ),
                activeAlertIDs: []
            )
        }

        XCTAssertEqual(
            evaluations.compactMap { $0.notifications.first?.body },
            [
                "Work Codex (ChatGPT / Codex): Warning status. Weekly current usage is 80% (Warning threshold: 75%).",
                "ChatGPT / Codex: Warning status. Weekly current usage is 80% (Warning threshold: 75%).",
                "ChatGPT / Codex 2 (ChatGPT / Codex): Warning status. Weekly current usage is 80% (Warning threshold: 75%).",
            ]
        )
        let notificationText = evaluations.flatMap(\.notifications).map {
            "\($0.title) \($0.body)"
        }.joined(separator: " ")
        XCTAssertFalse(notificationText.contains("first-private-id"))
        XCTAssertFalse(notificationText.contains("second-private-id"))
        XCTAssertFalse(notificationText.contains("third-private-id"))
    }

    func testUsageAlertEvaluatorExplainsProjectedSeverity() {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 40,
                    limit: 100,
                    projectionCurrent: 40,
                    projectionLimit: 100,
                    projectionPeriodStart: now.addingTimeInterval(-4 * 24 * 60 * 60),
                    projectionPeriodEnd: now.addingTimeInterval(6 * 24 * 60 * 60)
                ),
            ],
            fetchedAt: now
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.90,
            includesSeverityAlerts: true
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: [],
            now: now
        )

        XCTAssertEqual(evaluation.activeAlerts.first?.title, "Critical status")
        XCTAssertEqual(
            evaluation.notifications.first?.body,
            "Codex (ChatGPT / Codex): Critical status. Weekly projected usage is 100% (Critical threshold: 90%)."
        )
        XCTAssertEqual(
            evaluation.activeAlerts.first?.message,
            "Weekly projected usage is 100% (Critical threshold: 90%)."
        )
    }

    func testUsageAlertEvaluatorExplainsSpendLimitWithUserVisibleAccountTitles() {
        let results = [
            ProviderUsageResult(
                accountID: "cursor.work",
                providerID: .cursor,
                title: "Work Cursor",
                subtitle: "Included usage",
                bars: [],
                hasReachedSpendLimit: true,
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            ),
            ProviderUsageResult(
                accountID: "cursor.main",
                providerID: .cursor,
                title: "Cursor",
                subtitle: "Included usage",
                bars: [],
                hasReachedSpendLimit: true,
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            ),
        ]

        let evaluation = UsageAlertEvaluator.evaluate(
            results: results,
            settings: UsageAlertSettings(isEnabled: true, includesSeverityAlerts: true),
            activeAlertIDs: []
        )

        XCTAssertEqual(evaluation.notifications.map(\.kind), [.severity, .severity])
        XCTAssertEqual(evaluation.activeAlerts.map(\.title), ["Critical status", "Critical status"])
        XCTAssertEqual(
            evaluation.activeAlerts.map(\.message),
            [
                "Work Cursor reached its monthly usage-credit spend limit.",
                "Cursor reached its monthly usage-credit spend limit.",
            ]
        )
        XCTAssertEqual(
            evaluation.notifications.map(\.body),
            [
                "Work Cursor (Cursor): Critical status. Work Cursor reached its monthly usage-credit spend limit.",
                "Cursor: Critical status. Cursor reached its monthly usage-credit spend limit.",
            ]
        )
    }

    @MainActor
    func testLocalNotifierDeliversEvaluatorTitleAndAccountSpecificBody() throws {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Personal Codex",
            subtitle: "Live usage",
            bars: [UsageBar(label: "Weekly", used: 95, limit: 100)],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                usageThreshold: 1,
                includesSeverityAlerts: true
            ),
            activeAlertIDs: []
        )
        let notification = try XCTUnwrap(evaluation.notifications.first)

        let content = LocalUsageAlertNotifier.content(for: notification)

        XCTAssertEqual(content.title, "Personal Codex Critical alert")
        XCTAssertEqual(
            content.body,
            "Personal Codex (ChatGPT / Codex): Critical status. Weekly current usage is 95% (Critical threshold: 90%)."
        )
    }

    func testUsageAlertEvaluatorPrefersSpendLimitOverCriticalUsageInBothArrayOrders() {
        let bars = [
            UsageBar(stableKey: "five-hour", label: "5-hour", used: 91, limit: 100),
            UsageBar(stableKey: "weekly", label: "Weekly", used: 95, limit: 100),
        ]

        let evaluations = [bars, Array(bars.reversed())].map { orderedBars in
            let result = ProviderUsageResult(
                accountID: "cursor.work",
                providerID: .cursor,
                title: "Work Cursor",
                subtitle: "Included usage",
                bars: orderedBars,
                hasReachedSpendLimit: true,
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            )
            return UsageAlertEvaluator.evaluate(
                results: [result],
                settings: UsageAlertSettings(
                    isEnabled: true,
                    usageThreshold: 1,
                    includesSeverityAlerts: true
                ),
                activeAlertIDs: []
            )
        }

        XCTAssertTrue(evaluations.allSatisfy { evaluation in
            evaluation.notifications.map(\.body) == [
                "Work Cursor (Cursor): Critical status. Work Cursor reached its monthly usage-credit spend limit.",
            ]
        })
        XCTAssertTrue(evaluations.allSatisfy { evaluation in
            evaluation.activeAlerts.map(\.message) == [
                "Work Cursor reached its monthly usage-credit spend limit.",
            ]
        })
    }

    func testUsageAlertEvaluatorChoosesLargestCurrentCrossingRegardlessOfArrayOrder() {
        let bars = [
            UsageBar(stableKey: "five-hour", label: "5-hour", used: 105, limit: 100),
            UsageBar(stableKey: "weekly", label: "Weekly", used: 112, limit: 100),
        ]
        func makeResult(_ bars: [UsageBar]) -> ProviderUsageResult {
            ProviderUsageResult(
                accountID: "codex.personal",
                providerID: .codex,
                title: "Codex",
                subtitle: "Live usage",
                bars: bars,
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            )
        }

        let messages = [bars, Array(bars.reversed())].compactMap { orderedBars in
            UsageAlertEvaluator.evaluate(
                results: [makeResult(orderedBars)],
                settings: UsageAlertSettings(isEnabled: true, includesSeverityAlerts: true),
                activeAlertIDs: []
            ).notifications.first { $0.kind == .severity }?.body
        }

        XCTAssertEqual(
            messages,
            [
                "Codex (ChatGPT / Codex): Critical status. Weekly current usage is 112% (Critical threshold: 90%).",
                "Codex (ChatGPT / Codex): Critical status. Weekly current usage is 112% (Critical threshold: 90%).",
            ]
        )
    }

    func testUsageAlertEvaluatorPrefersObservedUsageOverProjectionInBothArrayOrders() {
        let now = Date(timeIntervalSince1970: 1_783_667_520)
        let bars = [
            UsageBar(stableKey: "current", label: "5-hour", used: 95, limit: 100),
            UsageBar(
                stableKey: "projected",
                label: "Weekly",
                used: 40,
                limit: 100,
                projectionCurrent: 40,
                projectionLimit: 100,
                projectionPeriodStart: now.addingTimeInterval(-4 * 24 * 60 * 60),
                projectionPeriodEnd: now.addingTimeInterval(6 * 24 * 60 * 60)
            ),
        ]

        let messages = [bars, Array(bars.reversed())].compactMap { orderedBars in
            let result = ProviderUsageResult(
                accountID: "codex.personal",
                providerID: .codex,
                title: "Codex",
                subtitle: "Live usage",
                bars: orderedBars,
                fetchedAt: now
            )
            return UsageAlertEvaluator.evaluate(
                results: [result],
                settings: UsageAlertSettings(
                    isEnabled: true,
                    usageThreshold: 1,
                    includesSeverityAlerts: true
                ),
                activeAlertIDs: [],
                now: now
            ).notifications.first { $0.kind == .severity }?.body
        }

        XCTAssertEqual(
            messages,
            [
                "Codex (ChatGPT / Codex): Critical status. 5-hour current usage is 95% (Critical threshold: 90%).",
                "Codex (ChatGPT / Codex): Critical status. 5-hour current usage is 95% (Critical threshold: 90%).",
            ]
        )
    }

    func testUsageAlertEvaluatorUsesStableMetricTieBreakers() {
        let bars = [
            UsageBar(stableKey: "zeta", label: "5-hour", used: 95, limit: 100),
            UsageBar(stableKey: "alpha", label: "Weekly", used: 95, limit: 100),
        ]

        let messages = [bars, Array(bars.reversed())].compactMap { orderedBars in
            let result = ProviderUsageResult(
                accountID: "codex.personal",
                providerID: .codex,
                title: "Codex",
                subtitle: "Live usage",
                bars: orderedBars,
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            )
            return UsageAlertEvaluator.evaluate(
                results: [result],
                settings: UsageAlertSettings(
                    isEnabled: true,
                    usageThreshold: 1,
                    includesSeverityAlerts: true
                ),
                activeAlertIDs: []
            ).activeAlerts.first { $0.kind == .severity }?.message
        }

        XCTAssertEqual(
            messages,
            [
                "Weekly current usage is 95% (Critical threshold: 90%).",
                "Weekly current usage is 95% (Critical threshold: 90%).",
            ]
        )
    }

    func testUsageAlertEvaluatorUsesLabelsWhenStableMetricKeysMatch() {
        let bars = [
            UsageBar(stableKey: "shared", label: "Weekly", used: 95, limit: 100),
            UsageBar(stableKey: "shared", label: "5-hour", used: 95, limit: 100),
        ]

        let evaluations = [bars, Array(bars.reversed())].map { orderedBars in
            let result = ProviderUsageResult(
                accountID: "codex.personal",
                providerID: .codex,
                title: "Codex",
                subtitle: "Live usage",
                bars: orderedBars,
                fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
            )
            return UsageAlertEvaluator.evaluate(
                results: [result],
                settings: UsageAlertSettings(
                    isEnabled: true,
                    usageThreshold: 1,
                    includesSeverityAlerts: true
                ),
                activeAlertIDs: []
            )
        }

        XCTAssertTrue(evaluations.allSatisfy { evaluation in
            evaluation.notifications.map(\.body) == [
                "Codex (ChatGPT / Codex): Critical status. 5-hour current usage is 95% (Critical threshold: 90%).",
            ]
        })
        XCTAssertTrue(evaluations.allSatisfy { evaluation in
            evaluation.activeAlerts.map(\.message) == [
                "5-hour current usage is 95% (Critical threshold: 90%).",
            ]
        })
    }

    func testUsageAlertEvaluatorReportsSeverityAlongsideSpecificThresholds() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    label: "Weekly usage limit",
                    used: 95,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: true
        )

        let first = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])
        let repeated = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertEqual(first.notifications.map(\.title), ["Codex Weekly usage limit alert", "Codex Critical alert"])
        XCTAssertEqual(first.activeAlertIDs, ["usage.codex.personal.weekly-usage-limit", "severity.codex.personal.2"])
        XCTAssertEqual(first.activeAlerts.map(\.accountID), ["codex.personal", "codex.personal"])
        XCTAssertTrue(repeated.notifications.isEmpty)
    }

    func testUsageAlertEvaluatorPreservesClaudeWeeklyAlertIdentity() {
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    stableKey: "weekly-all",
                    label: "All models weekly usage limit",
                    used: 90,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let legacyAlertID = "usage.claude.personal.weekly-usage-limit"

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                usageThreshold: 0.80,
                includesSeverityAlerts: false
            ),
            activeAlertIDs: [legacyAlertID]
        )

        XCTAssertTrue(evaluation.notifications.isEmpty)
        XCTAssertEqual(evaluation.activeAlertIDs, [legacyAlertID])
    }

    func testUsageAlertEvaluatorPreservesCodexGeneralWindowAlertIdentities() {
        let resetAt = Date(timeIntervalSince1970: 1_893_456_000)
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    stableKey: "window-18000",
                    label: "5 hour usage limit",
                    used: 90,
                    limit: 100,
                    resetsAt: resetAt
                ),
                UsageBar(
                    stableKey: "window-604800",
                    label: "Weekly usage limit",
                    used: 90,
                    limit: 100,
                    resetsAt: resetAt
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_893_369_600)
        )
        let legacyAlertIDs: Set<String> = [
            "usage.codex.personal.hour-usage-limit.1893456000",
            "usage.codex.personal.weekly-usage-limit.1893456000",
        ]

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                usageThreshold: 0.80,
                includesSeverityAlerts: false
            ),
            activeAlertIDs: legacyAlertIDs
        )

        XCTAssertTrue(evaluation.notifications.isEmpty)
        XCTAssertEqual(evaluation.activeAlertIDs, legacyAlertIDs)
    }

    func testUsageAlertEvaluatorNotifiesWhenSeverityEscalates() {
        let warningResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Weekly", used: 76, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let criticalResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "Weekly", used: 95, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.90,
            includesSeverityAlerts: true
        )

        let warningEvaluation = UsageAlertEvaluator.evaluate(
            results: [warningResult],
            settings: settings,
            activeAlertIDs: []
        )
        let criticalEvaluation = UsageAlertEvaluator.evaluate(
            results: [criticalResult],
            settings: settings,
            activeAlertIDs: warningEvaluation.activeAlertIDs
        )

        XCTAssertEqual(warningEvaluation.notifications.map(\.kind), [.severity])
        XCTAssertEqual(
            criticalEvaluation.notifications.filter { $0.kind == .severity }.map(\.title),
            ["Codex Critical alert"]
        )
        XCTAssertTrue(criticalEvaluation.activeAlertIDs.contains("severity.codex.personal.2"))
    }

    func testUsageAlertEvaluatorAlertsWhenNewWindowStartsAboveThreshold() {
        let previousWindowReset = Date(timeIntervalSince1970: 1_783_600_000)
        let nextWindowReset = Date(timeIntervalSince1970: 1_784_200_000)
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            includesSeverityAlerts: false
        )
        let previousWindow = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 95,
                    limit: 100,
                    resetsAt: previousWindowReset
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let nextWindow = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 95,
                    limit: 100,
                    resetsAt: nextWindowReset
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_784_000_000)
        )

        let first = UsageAlertEvaluator.evaluate(results: [previousWindow], settings: settings, activeAlertIDs: [])
        let second = UsageAlertEvaluator.evaluate(
            results: [nextWindow],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(second.notifications.count, 1)
        XCTAssertNotEqual(first.activeAlertIDs, second.activeAlertIDs)
    }

}
