import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class OpenCodeProviderTests: XCTestCase {
    deinit {}

    func testOpenCodeZenBalanceParserReadsJSONBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.accountLabel = "OpenCode ZEN API"
        let payload = """
        {
          "data": {
            "balance": 42.5,
            "currency": "USD"
          }
        }
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.title, "OpenCode ZEN API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(result.creditsRemaining, 42.5)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsDashboardNanodollarBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = #"initial:{balance:1250000000,credits:[]}"#

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.5, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeGoParserReadsHydrationWindowsWithStableKeysAndPreciseProjections() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_784_980_800) // 2026-07-25 12:00 UTC
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = """
        <script>
        window.data = {
          "monthlyUsage": {"resetInSec": 1814400, "usagePercent": 20},
          "rollingUsage": {"avgUsagePercent": 99, "usagePercent": 80, "resetInSec": 3600},
          "weeklyUsage": {"resetInSec": 129600, "usagePercent": 40}
        };
        </script>
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.title, "OpenCode Go")
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "go.rolling-5-hour",
            "go.weekly",
            "go.monthly",
        ])
        XCTAssertEqual(result.bars.map(\.used), [80, 40, 20])
        XCTAssertEqual(result.bars.map(\.resetsAt), [
            fetchedAt.addingTimeInterval(3_600),
            fetchedAt.addingTimeInterval(129_600),
            fetchedAt.addingTimeInterval(1_814_400),
        ])
        XCTAssertEqual(result.bars.map(\.projectionCurrent), [0.8, 0.4, 0.2])
        XCTAssertEqual(result.bars.map(\.projectionLimit), [1, 1, 1])
        XCTAssertTrue(result.bars.allSatisfy(\.showProjectionOnCurrentBar))
    }

    func testOpenCodeGoParserFallsBackToRenderedHTMLWithoutApproximateProjections() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = """
        <div data-slot="usage-item">
          <span data-slot="usage-label">Monthly Usage</span>
          <span data-slot="usage-value">6.5%</span>
          <span data-slot="reset-time">Resets in 29 days 4 hours</span>
        </div>
        <div data-slot="usage-item">
          <span data-slot="usage-label">Rolling Usage</span>
          <span data-slot="usage-value">10.25%</span>
          <span data-slot="reset-time">Resets in 1 hour 30 minutes</span>
        </div>
        <div data-slot="usage-item">
          <span data-slot="usage-label">Weekly Usage</span>
          <span data-slot="usage-value">20%</span>
          <span data-slot="reset-time">Resets in 2 days 3 hours</span>
        </div>
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.used), [10.25, 20, 6.5])
        XCTAssertEqual(result.bars.map(\.resetsAt), [
            fetchedAt.addingTimeInterval(5_400),
            fetchedAt.addingTimeInterval(183_600),
            fetchedAt.addingTimeInterval(2_520_000),
        ])
        XCTAssertTrue(result.bars.allSatisfy { $0.projectionCurrent == nil })
        XCTAssertTrue(result.bars.allSatisfy { !$0.showProjectionOnCurrentBar })

        let ambiguousReset = payload.replacingOccurrences(
            of: "Resets in 1 hour 30 minutes",
            with: "Resets in a few minutes"
        )
        XCTAssertNil(OpenCodeZenUsageProvider.parseGoUsage(
            Data(ambiguousReset.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        let nearReset = payload.replacingOccurrences(
            of: "Resets in 1 hour 30 minutes",
            with: "Resets in less than a minute"
        )
        XCTAssertEqual(
            try XCTUnwrap(OpenCodeZenUsageProvider.parseGoUsage(
                Data(nearReset.utf8),
                configuration: configuration,
                fetchedAt: fetchedAt
            )).bars.first?.resetsAt,
            fetchedAt
        )
    }

    func testOpenCodeGoParserRejectsPartialAndMalformedWindows() {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let partial = """
        {"rollingUsage":{"usagePercent":12,"resetInSec":300},
         "weeklyUsage":{"usagePercent":20,"resetInSec":600}}
        """

        XCTAssertNil(OpenCodeZenUsageProvider.parseGoUsage(
            Data(partial.utf8),
            configuration: configuration
        ))
        XCTAssertNil(OpenCodeZenUsageProvider.parseGoUsage(
            Data("<html>unexpected dashboard</html>".utf8),
            configuration: configuration
        ))
    }

    func testOpenCodeDisplayNameDistinguishesGeneratedProductStatesAndPreservesCustomLabels() {
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)

        XCTAssertEqual(configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: true), "OpenCode Go + Zen")
        XCTAssertEqual(configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: false), "OpenCode Go")
        XCTAssertEqual(configuration.openCodeDisplayName(hasGoUsage: false, hasZenBalance: true), "OpenCode ZEN")

        configuration.accountLabel = "OpenCode ZEN 2"
        XCTAssertEqual(configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: false), "OpenCode Go 2")
        XCTAssertEqual(configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: true), "OpenCode Go + Zen 2")

        configuration.accountLabel = "OpenCode Go 2"
        XCTAssertEqual(configuration.openCodeDisplayName(hasGoUsage: false, hasZenBalance: true), "OpenCode ZEN 2")

        configuration.accountLabel = "Team OpenCode"
        XCTAssertEqual(configuration.openCodeDisplayName(hasGoUsage: true, hasZenBalance: true), "Team OpenCode")
    }

    @MainActor
    func testAppModelPreservesGeneratedOpenCodeProductTitle() {
        let suiteName = "CodexBarMacTests.OpenCodeTitle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: InMemorySecretStore()
        )
        configurationStore.seedDefaultConfigurationsIfNeeded()
        let configuration = configurationStore.configuration(for: .openCodeZen)
        var numberedConfiguration = configuration
        numberedConfiguration.accountLabel = "OpenCode ZEN 2"
        XCTAssertTrue(configurationStore.update(numberedConfiguration))
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: "OpenCode Go + Zen 2",
            subtitle: "Go usage and ZEN credit balance",
            bars: [UsageBar(stableKey: "go.weekly", label: "Weekly usage limit", used: 20, limit: 100)],
            creditsRemaining: 12.25,
            fetchedAt: Date(timeIntervalSince1970: 1_784_980_800)
        )
        let model = AppModel(
            refreshService: UsageRefreshService(providers: [], initialResults: [result]),
            configurationStore: configurationStore,
            historyStore: UsageHistoryStore(defaults: defaults),
            launchAtLoginManager: LaunchAtLoginManager(defaults: defaults),
            usageAlertNotifier: StubUsageAlertNotifier()
        )

        XCTAssertEqual(model.displayedResults.first?.title, "OpenCode Go + Zen 2")

        var customConfiguration = numberedConfiguration
        customConfiguration.accountLabel = "Team OpenCode"
        XCTAssertTrue(configurationStore.update(customConfiguration))
        XCTAssertEqual(model.displayedResults.first?.title, "Team OpenCode")
    }

    func testOpenCodeProviderReturnsGoUsageAndZenBalanceTogether() async throws {
        let secretStore = InMemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_redacted"
        try secretStore.saveSecret(
            "redacted-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = OpenCodeZenUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: urlSessionConfiguration)
        )
        let goPayload = """
        {"rollingUsage":{"usagePercent":11.25,"resetInSec":300},
         "weeklyUsage":{"usagePercent":22.5,"resetInSec":600},
         "monthlyUsage":{"usagePercent":33.75,"resetInSec":900}}
        """

        MockURLProtocol.handler = { request in
            let data = request.url?.path.hasSuffix("/go") == true
                ? Data(goPayload.utf8)
                : Data("<html>balance:1875000000</html>".utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.title, "OpenCode Go + Zen")
        XCTAssertEqual(result.subtitle, "Go usage and ZEN credit balance")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 18.75, accuracy: 0.0001)
        XCTAssertEqual(result.bars.map(\.used), [11.25, 22.5, 33.75])
        XCTAssertTrue(result.usageMessages.isEmpty)
        XCTAssertFalse(result.isIncompleteRefresh)
        XCTAssertEqual(result.cacheScope, "wrk_redacted")
        XCTAssertNotNil(result.cacheIdentity)
        XCTAssertNotEqual(result.cacheIdentity, "redacted-dashboard-token")
    }

    func testOpenCodeProviderPreservesEachIndependentDashboardResult() async throws {
        let secretStore = InMemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_redacted"
        try secretStore.saveSecret(
            "redacted-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = OpenCodeZenUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: urlSessionConfiguration)
        )
        let goPayload = """
        {"rollingUsage":{"usagePercent":10,"resetInSec":300},
         "weeklyUsage":{"usagePercent":20,"resetInSec":600},
         "monthlyUsage":{"usagePercent":30,"resetInSec":900}}
        """
        MockURLProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            let data = path.hasSuffix("/go")
                ? Data("<html>malformed</html>".utf8)
                : Data("<html>balance:1225000000</html>".utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer { MockURLProtocol.handler = nil }

        let balanceOnly = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(balanceOnly.title, "OpenCode ZEN")
        XCTAssertEqual(try XCTUnwrap(balanceOnly.creditsRemaining), 12.25, accuracy: 0.0001)
        XCTAssertTrue(balanceOnly.bars.isEmpty)
        XCTAssertEqual(balanceOnly.usageMessages, [
            "Go usage unavailable: Could not parse all OpenCode Go usage windows.",
        ])
        XCTAssertTrue(balanceOnly.preservesCachedBarsOnIncompleteRefresh)
        XCTAssertFalse(balanceOnly.preservesCachedCreditsOnIncompleteRefresh)
        XCTAssertTrue(balanceOnly.isIncompleteRefresh)

        MockURLProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            let data = path.hasSuffix("/billing")
                ? Data("<html>malformed</html>".utf8)
                : Data(goPayload.utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        let goOnly = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(goOnly.title, "OpenCode Go")
        XCTAssertNil(goOnly.creditsRemaining)
        XCTAssertEqual(goOnly.bars.map(\.used), [10, 20, 30])
        XCTAssertEqual(goOnly.usageMessages, [
            "ZEN balance unavailable: Could not parse OpenCode ZEN balance.",
        ])
        XCTAssertFalse(goOnly.preservesCachedBarsOnIncompleteRefresh)
        XCTAssertTrue(goOnly.preservesCachedCreditsOnIncompleteRefresh)
        XCTAssertTrue(goOnly.isIncompleteRefresh)
    }

    func testOpenCodeProviderReportsUnsubscribedAndOtherMemberStatesWithoutDroppingBalance() async throws {
        let secretStore = InMemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_redacted"
        try secretStore.saveSecret(
            "redacted-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = OpenCodeZenUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: urlSessionConfiguration)
        )
        MockURLProtocol.handler = { request in
            let data = request.url?.path.hasSuffix("/go") == true
                ? Data(#"<div data-slot="promo-description">Subscribe to Go</div>"#.utf8)
                : Data("<html>balance:1225000000</html>".utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer { MockURLProtocol.handler = nil }

        let unsubscribed = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(unsubscribed.subtitle, "ZEN credit balance - Go not subscribed")
        XCTAssertEqual(unsubscribed.usageMessages, ["This workspace is not subscribed to OpenCode Go."])
        XCTAssertEqual(try XCTUnwrap(unsubscribed.creditsRemaining), 12.25, accuracy: 0.0001)

        MockURLProtocol.handler = { request in
            let data = request.url?.path.hasSuffix("/go") == true
                ? Data(#"<div data-slot="other-message">OpenCode Go is owned by another member.</div>"#.utf8)
                : Data("<html>balance:1225000000</html>".utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        let otherMember = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(otherMember.subtitle, "ZEN credit balance - Go owned by another member")
        XCTAssertEqual(otherMember.usageMessages, [
            "Another workspace member owns the OpenCode Go subscription.",
        ])
        XCTAssertEqual(try XCTUnwrap(otherMember.creditsRemaining), 12.25, accuracy: 0.0001)
    }

    func testOpenCodeZenProviderFetchesDashboardBillingBalance() async throws {
        let secretStore = InMemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "opencode.ai")
            XCTAssertTrue([
                "/workspace/wrk_test/billing",
                "/workspace/wrk_test/go",
            ].contains(request.url?.path))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                request.url?.path.hasSuffix("/go") == true
                    ? Data(#"<div data-slot="promo-description">Subscribe to Go</div>"#.utf8)
                    : Data(#"<html>data balance:2575000000 more</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 25.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderExplainsModelAPIKeyCannotFetchBalanceAfterDashboardRejectsIt() async throws {
        let secretStore = InMemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "sk-opencode-model-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=sk-opencode-model-key")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"<html><title>OpenAuth</title></html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(
            result.subtitle,
            "OpenCode ZEN API keys are valid for models, but OpenCode does not expose balance to API keys."
        )
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderReadsWindowsSettingsJSONCredentialAndWorkspace() async throws {
        let secretStore = InMemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = ""
        let windowsSettings = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "enabled": true,
              "apiKey": "go-dashboard-token"
            },
            "OpenCodeZen": {
              "enabled": true
            }
          }
        }
        """
        try secretStore.saveSecret(
            windowsSettings,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertTrue([
                "/workspace/wrk_from_windows/billing",
                "/workspace/wrk_from_windows/go",
            ].contains(request.url?.path))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=go-dashboard-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                request.url?.path.hasSuffix("/go") == true
                    ? Data(#"<div data-slot="promo-description">Subscribe to Go</div>"#.utf8)
                    : Data(#"<html>balance:625000000</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 6.25, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderPrefersGoDashboardCredentialOverZenModelKey() async throws {
        let secretStore = InMemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_from_windows"
        let windowsSettings = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            },
            "OpenCodeZen": {
              "apiKey": "sk-opencode-model-key"
            }
          }
        }
        """
        try secretStore.saveSecret(
            windowsSettings,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=go-dashboard-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                request.url?.path.hasSuffix("/go") == true
                    ? Data(#"<div data-slot="promo-description">Subscribe to Go</div>"#.utf8)
                    : Data(#"<html>balance:100000000</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 1.0, accuracy: 0.0001)
    }

}
