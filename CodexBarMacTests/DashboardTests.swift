import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class DashboardTests: XCTestCase {
    deinit {}

    @MainActor
    func testProviderSettingsRowAccessibilityDescribesCredentialStatusOnce() {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)

        XCTAssertEqual(
            ProviderSettingsRow.accessibilityValue(
                configuration: configuration,
                readiness: .keychainSaved
            ),
            "Keychain credential saved"
        )
        XCTAssertEqual(
            ProviderSettingsRow.accessibilityValue(
                configuration: configuration,
                readiness: .localCLIReady(description: "Claude Code")
            ),
            "Local credentials ready (Claude Code)"
        )
        XCTAssertEqual(
            ProviderSettingsRow.accessibilityValue(
                configuration: configuration,
                readiness: .error(description: "Credential expired")
            ),
            "Credential expired"
        )
        XCTAssertEqual(
            ProviderSettingsRow.accessibilityValue(
                configuration: configuration,
                readiness: .missing
            ),
            "Needs credentials"
        )

        configuration.isEnabled = false
        XCTAssertEqual(
            ProviderSettingsRow.accessibilityValue(
                configuration: configuration,
                readiness: .keychainSaved
            ),
            "Disabled"
        )
    }

    @MainActor
    func testDashboardOrderingModeDefaultsToManualAndPersists() {
        let suiteName = "CodexBarMacTests.DashboardOrdering.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertEqual(store.dashboardOrderingMode, .manual)

        store.updateDashboardOrderingMode(.smart)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertEqual(reloadedStore.dashboardOrderingMode, .smart)
    }

    func testDashboardUsageSorterOrdersSmartResultsByUrgency() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let periodStart = now.addingTimeInterval(-2 * 60 * 60)
        let periodEnd = now.addingTimeInterval(3 * 60 * 60)
        let alphabeticalNormal = ProviderUsageResult(
            accountID: "normal.alpha",
            providerID: .claude,
            title: "Alpha",
            subtitle: "Live",
            bars: [UsageBar(label: "Weekly", used: 20, limit: 100)],
            fetchedAt: now
        )
        let criticalProjection = ProviderUsageResult(
            accountID: "critical.projection",
            providerID: .codex,
            title: "Critical",
            subtitle: "Live",
            bars: [
                UsageBar(
                    label: "Weekly",
                    used: 20,
                    limit: 100,
                    projectionCurrent: 80,
                    projectionLimit: 100,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd
                ),
            ],
            fetchedAt: now
        )
        let highBalance = ProviderUsageResult(
            accountID: "balance.high",
            providerID: .openRouter,
            title: "High Balance",
            subtitle: "Live",
            bars: [],
            creditsRemaining: 20,
            fetchedAt: now
        )
        let lowBalance = ProviderUsageResult(
            accountID: "balance.low",
            providerID: .openRouter,
            title: "Low Balance",
            subtitle: "Live",
            bars: [],
            creditsRemaining: 2,
            fetchedAt: now
        )
        let warningUsage = ProviderUsageResult(
            accountID: "warning.usage",
            providerID: .cursor,
            title: "Warning",
            subtitle: "Live",
            bars: [UsageBar(label: "Monthly", used: 80, limit: 100)],
            fetchedAt: now
        )
        let laterNormal = ProviderUsageResult(
            accountID: "normal.zeta",
            providerID: .gemini,
            title: "Zeta",
            subtitle: "Live",
            bars: [UsageBar(label: "Daily", used: 20, limit: 100)],
            fetchedAt: now
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [alphabeticalNormal, criticalProjection, highBalance, lowBalance, warningUsage, laterNormal],
            mode: .smart,
            now: now
        )

        XCTAssertEqual(
            ordered.map(\.accountID),
            [
                "critical.projection",
                "warning.usage",
                "balance.low",
                "balance.high",
                "normal.alpha",
                "normal.zeta",
            ]
        )
    }

    func testDashboardUsageSorterKeepsInputOrderInManualMode() {
        let now = Date(timeIntervalSince1970: 1_788_475_200)
        let critical = ProviderUsageResult(
            accountID: "critical",
            providerID: .codex,
            title: "Critical",
            subtitle: "Live",
            bars: [UsageBar(label: "Weekly", used: 95, limit: 100)],
            fetchedAt: now
        )
        let normal = ProviderUsageResult(
            accountID: "normal",
            providerID: .cursor,
            title: "Normal",
            subtitle: "Live",
            bars: [UsageBar(label: "Monthly", used: 10, limit: 100)],
            fetchedAt: now
        )

        let ordered = DashboardUsageSorter.orderedResults(
            [normal, critical],
            mode: .manual,
            now: now
        )

        XCTAssertEqual(ordered.map(\.accountID), ["normal", "critical"])
    }

    @MainActor
    func testDiscoveredDashboardMetricsUseStableKeysWithoutMergingEqualLabels() {
        let result = ProviderUsageResult(
            accountID: "codex.work",
            providerID: .codex,
            title: "Work Codex",
            subtitle: "Live",
            bars: [
                UsageBar(stableKey: "window-604800", label: "Weekly", used: 20, limit: 100),
                UsageBar(
                    stableKey: "bucket-spark.window-18000",
                    label: "Model limit",
                    used: 30,
                    limit: 100
                ),
                UsageBar(
                    stableKey: "bucket-other.window-18000",
                    label: "Model limit",
                    used: 40,
                    limit: 100
                ),
                UsageBar(label: "Legacy label only", used: 50, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let metrics = ProviderSettingsView.dashboardMetrics(from: result)

        XCTAssertEqual(
            metrics.map(\.id),
            ["window-604800", "bucket-spark.window-18000", "bucket-other.window-18000"]
        )
        XCTAssertEqual(metrics.map(\.label), ["Weekly", "Model limit", "Model limit"])
        XCTAssertEqual(
            ProviderSettingsView.metricAccessibilityLabel(
                accountName: "Work Codex",
                metricName: "Weekly"
            ),
            "Show Weekly for Work Codex"
        )
    }

    @MainActor
    func testMetricDiscoveryFailurePromptsRetryInsteadOfReportingNoMetrics() {
        let failedResult = ProviderUsageResult(
            accountID: "codex.work",
            providerID: .codex,
            title: "Work Codex",
            subtitle: "Request timed out",
            bars: [],
            isIncompleteRefresh: true,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let completedEmptyResult = ProviderUsageResult(
            accountID: "codex.work",
            providerID: .codex,
            title: "Work Codex",
            subtitle: "Live",
            bars: [],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        XCTAssertEqual(
            ProviderSettingsView.metricsEmptyStateMessage(
                for: failedResult,
                isAccountEnabled: true
            ),
            "Could not discover dashboard metrics (Request timed out). "
                + "Select Refresh Metrics to try again."
        )
        XCTAssertEqual(
            ProviderSettingsView.metricsEmptyStateMessage(
                for: completedEmptyResult,
                isAccountEnabled: true
            ),
            "This account has no configurable dashboard metrics."
        )

        let failedCachedResult = ProviderUsageResult(
            accountID: "codex.work",
            providerID: .codex,
            title: "Work Codex",
            subtitle: "Request timed out",
            bars: [UsageBar(stableKey: "weekly", label: "Weekly", used: 40, limit: 100)],
            isIncompleteRefresh: true,
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_060)
        )
        XCTAssertEqual(
            ProviderSettingsView.dashboardMetrics(from: failedCachedResult).map(\.id),
            ["weekly"]
        )
        XCTAssertEqual(
            ProviderSettingsView.metricsRefreshFailureMessage(for: failedCachedResult),
            "Could not discover dashboard metrics (Request timed out). "
                + "Select Refresh Metrics to try again."
        )
    }

    @MainActor
    func testAllHiddenStableBarsLeaveCardStateAndOtherContentAvailable() {
        let bars = [
            UsageBar(stableKey: "five-hour", label: "5-hour", used: 95, limit: 100),
            UsageBar(stableKey: "weekly", label: "Weekly", used: 40, limit: 100),
        ]
        let monetaryMetric = ProviderMonetaryMetric(
            kind: .spent,
            label: "Spent",
            minorUnits: 250,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        let result = ProviderUsageResult(
            accountID: "codex.work",
            providerID: .codex,
            title: "Work Codex",
            subtitle: "Live",
            bars: bars,
            creditsRemaining: 12,
            monetaryMetrics: [monetaryMetric],
            usageMessages: ["Provider notice"],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let hiddenUsageAlert = UsageAlertDetail(
            id: UsageAlertEvaluator.usageAlertID(for: result, bar: bars[0]),
            accountID: result.accountID,
            kind: .usage,
            title: "5-hour at 95%",
            message: "95 of 100 used. Alert threshold: 90%.",
            severity: .critical
        )
        let visibleUsageAlert = UsageAlertDetail(
            id: UsageAlertEvaluator.usageAlertID(for: result, bar: bars[1]),
            accountID: result.accountID,
            kind: .usage,
            title: "Weekly at 40%",
            message: "40 of 100 used. Alert threshold: 30%.",
            severity: .warning
        )
        let card = ProviderUsageCard(
            result: result,
            historyOptions: [],
            alerts: [hiddenUsageAlert, visibleUsageAlert],
            isHistoryEnabled: true,
            hiddenMetricKeys: ["five-hour", "weekly"]
        )

        XCTAssertTrue(card.visibleBars.isEmpty)
        XCTAssertEqual(card.cardSeverity, .critical)
        XCTAssertTrue(card.showsHistory)
        XCTAssertTrue(card.showsCreditBalance)
        XCTAssertEqual(card.displayedAlerts, [hiddenUsageAlert, visibleUsageAlert])
        XCTAssertTrue(card.hiddenAlerts.isEmpty)
        XCTAssertTrue(card.showsAlertSummary)
        XCTAssertEqual(card.result.monetaryMetrics, [monetaryMetric])
        XCTAssertEqual(card.result.usageMessages, ["Provider notice"])

        let partlyHiddenCard = ProviderUsageCard(
            result: result,
            historyOptions: [],
            alerts: [hiddenUsageAlert, visibleUsageAlert],
            isHistoryEnabled: true,
            hiddenMetricKeys: ["five-hour"]
        )
        XCTAssertEqual(partlyHiddenCard.displayedAlerts, [hiddenUsageAlert])
        XCTAssertEqual(partlyHiddenCard.hiddenAlerts, [visibleUsageAlert])
    }

    @MainActor
    func testBarsWithoutStableKeysRemainVisible() {
        let keyed = UsageBar(stableKey: "weekly", label: "Weekly", used: 40, limit: 100)
        let unkeyed = UsageBar(label: "Legacy", used: 20, limit: 100)
        let result = ProviderUsageResult(
            providerID: .codex,
            title: "Codex",
            subtitle: "Live",
            bars: [keyed, unkeyed],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let card = ProviderUsageCard(
            result: result,
            historyOptions: [],
            isHistoryEnabled: false,
            hiddenMetricKeys: ["weekly"]
        )

        XCTAssertEqual(card.visibleBars, [unkeyed])
    }

    @MainActor
    func testHiddenNonCodexMetricRetainsAccessibleCardSeverity() {
        let result = ProviderUsageResult(
            accountID: "claude.personal",
            providerID: .claude,
            title: "Claude",
            subtitle: "Live",
            bars: [UsageBar(stableKey: "weekly", label: "Weekly", used: 95, limit: 100)],
            fetchedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let card = ProviderUsageCard(
            result: result,
            historyOptions: [],
            alerts: [],
            isHistoryEnabled: false,
            hiddenMetricKeys: ["weekly"]
        )

        XCTAssertTrue(card.visibleBars.isEmpty)
        XCTAssertEqual(card.cardSeverity, .critical)
        XCTAssertTrue(card.showsCardSeverityAccessibility)
        XCTAssertEqual(card.cardSeverityAccessibilityLabel, "Claude Critical status.")
    }

}
