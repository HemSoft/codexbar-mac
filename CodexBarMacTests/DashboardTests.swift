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

}
