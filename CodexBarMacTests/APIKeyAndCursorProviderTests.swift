import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class APIKeyAndCursorProviderTests: XCTestCase {
    deinit {}

    func testOpenRouterCreditsParserCalculatesBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration(
            providerID: .openRouter,
            accountLabel: "OpenRouter API",
            authMethod: .apiKey
        )
        let payload = """
        {
          "data": {
            "total_credits": 25.5,
            "total_usage": 7.25
          }
        }
        """

        let result = try XCTUnwrap(OpenRouterUsageProvider.parseCredits(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.title, "OpenRouter API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 18.25, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenRouterCreditsParserRejectsMissingCreditFields() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        let payload = """
        {
          "data": {
            "usage": 7.25
          }
        }
        """

        let result = OpenRouterUsageProvider.parseCredits(
            Data(payload.utf8),
            configuration: configuration
        )

        XCTAssertNil(result)
    }

    func testOpenRouterProviderFetchesKeyBalance() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        try secretStore.saveSecret("Bearer sk-or-test", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = OpenRouterUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CodexBarMac/1.0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "CodexBar")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"data":{"total_credits":100,"total_usage":12.34}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 87.66, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenRouterProviderRejectsInvalidAPIKey() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        try secretStore.saveSecret("sk-or-invalid", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = OpenRouterUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.subtitle, "OpenRouter rejected this API key.")
        XCTAssertNil(result.creditsRemaining)
    }

    func testOpenRouterProviderExplainsManagementKeyRequirement() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        try secretStore.saveSecret("sk-or-inference", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = OpenRouterUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":{"message":"Only management keys can perform this operation"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.subtitle, "OpenRouter requires a management API key for credit balance.")
        XCTAssertNil(result.creditsRemaining)
    }

    func testOpenRouterNormalizesPastedAuthorizationHeader() {
        XCTAssertEqual(
            OpenRouterUsageProvider.normalizedAPIKey(from: "Authorization: Bearer sk-or-test"),
            "sk-or-test"
        )
        XCTAssertEqual(
            OpenRouterUsageProvider.normalizedAPIKey(from: "\"sk-or-quoted\""),
            "sk-or-quoted"
        )
    }

    func testOpenRouterProviderWithoutCredentialShowsActionableError() async throws {
        let provider = OpenRouterUsageProvider(secretStore: InMemorySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - enter API key.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testMoonshotBalanceParserReadsAvailableBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration(
            providerID: .moonshot,
            accountLabel: "Moonshot API",
            authMethod: .apiKey
        )
        let payload = """
        {
          "code": 0,
          "data": {
            "available_balance": 49.58894,
            "voucher_balance": 46.58893,
            "cash_balance": 3.00001
          },
          "scode": "0x0",
          "status": true
        }
        """

        let result = try XCTUnwrap(MoonshotUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(result.title, "Moonshot API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 49.58894, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }

    func testMoonshotBalanceParserRejectsMissingBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        let payload = """
        {
          "code": 0,
          "data": {
            "voucher_balance": 46.58893
          },
          "status": true
        }
        """

        let result = MoonshotUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        )

        XCTAssertNil(result)
    }

    func testMoonshotProviderFetchesBalance() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        try secretStore.saveSecret("Bearer sk-moonshot-test", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = MoonshotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.moonshot.ai/v1/users/me/balance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-moonshot-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "CodexBarMac/1.0")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"code":0,"data":{"available_balance":37.5,"voucher_balance":30,"cash_balance":7.5},"scode":"0x0","status":true}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 37.5, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testMoonshotProviderRejectsInvalidAPIKey() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        try secretStore.saveSecret("sk-moonshot-bad", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = MoonshotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.subtitle, "Moonshot rejected this API key.")
        XCTAssertNil(result.creditsRemaining)
    }

    func testMoonshotProviderReportsRateLimit() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        try secretStore.saveSecret("sk-moonshot-test", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = MoonshotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 429, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.subtitle, "Moonshot rate limit reached. Try again later.")
        XCTAssertNil(result.creditsRemaining)
    }

    func testMoonshotNormalizesPastedAuthorizationHeader() {
        XCTAssertEqual(
            MoonshotUsageProvider.normalizedAPIKey(from: "Authorization: Bearer sk-moonshot-test"),
            "sk-moonshot-test"
        )
        XCTAssertEqual(
            MoonshotUsageProvider.normalizedAPIKey(from: "\"sk-moonshot-quoted\""),
            "sk-moonshot-quoted"
        )
    }

    func testMoonshotProviderWithoutCredentialShowsActionableError() async throws {
        let provider = MoonshotUsageProvider(secretStore: InMemorySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - enter API key.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCursorAuthURLUsesBrowserPollingFlow() throws {
        let url = CursorWebAuthService.authorizationURL(
            uuid: "request-id",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "cursor.com")
        XCTAssertEqual(components.path, "/loginDeepControl")
        XCTAssertEqual(components.queryItemValue(named: "challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "uuid"), "request-id")
        XCTAssertEqual(components.queryItemValue(named: "mode"), "login")
        XCTAssertEqual(components.queryItemValue(named: "redirectTarget"), "cli")
    }

    func testCursorPollRequestUsesPKCEVerifier() throws {
        let request = CursorWebAuthService.pollRequest(uuid: "request-id", codeVerifier: "verifier")
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api2.cursor.sh")
        XCTAssertEqual(components.path, "/auth/poll")
        XCTAssertEqual(components.queryItemValue(named: "uuid"), "request-id")
        XCTAssertEqual(components.queryItemValue(named: "verifier"), "verifier")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    @MainActor
    func testCursorBrowserSignInPollsAndStoresSessionShape() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )

        MockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.host, "api2.cursor.sh")
            XCTAssertEqual(components.path, "/auth/poll")
            XCTAssertNotNil(components.queryItemValue(named: "uuid"))
            XCTAssertNotNil(components.queryItemValue(named: "verifier"))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"accessToken":"cursor-access","refreshToken":"cursor-refresh","authId":"auth0|user-id"}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        var presentedURL: URL?
        let result = try await service.signIn { url in
            presentedURL = url
            return true
        }
        let authURL = try XCTUnwrap(presentedURL)
        let authComponents = try XCTUnwrap(URLComponents(url: authURL, resolvingAgainstBaseURL: false))

        XCTAssertEqual(authComponents.host, "cursor.com")
        XCTAssertEqual(result.accessToken, "cursor-access")
        XCTAssertEqual(result.refreshToken, "cursor-refresh")
        XCTAssertTrue(result.storedCredential.contains(#""accessToken": "cursor-access""#))
    }

    @MainActor
    func testCursorBrowserSignInSanitizesTokenPollFailure() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )
        let secret = "cursor-token-\(String(repeating: "x", count: 4_096))"

        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(
                    """
                    {"error":"invalid_grant","error_description":"authorization: Bearer \(secret)\\nnext-line\\u0007"}
                    """.utf8
                )
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        do {
            _ = try await service.signIn { _ in true }
            XCTFail("Expected Cursor sign-in to fail.")
        } catch {
            XCTAssertEqual(
                error as? CursorWebAuthService.AuthError,
                .tokenPollFailed("HTTP 400 (invalid_grant)")
            )
            XCTAssertFalse(error.localizedDescription.contains(secret))
            XCTAssertFalse(error.localizedDescription.contains("next-line"))
            XCTAssertFalse(error.localizedDescription.contains("\u{0007}"))
        }
    }

    @MainActor
    func testCursorBrowserSignInRejectsOversizedOrControlledOAuthErrorCodes() async throws {
        let unsafeErrorCodes = [
            String(repeating: "x", count: 65),
            "authorization_\u{0007}pending",
            "expired\ntoken",
        ]
        defer {
            MockURLProtocol.handler = nil
        }

        for unsafeErrorCode in unsafeErrorCodes {
            let urlSessionConfiguration = URLSessionConfiguration.ephemeral
            urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: urlSessionConfiguration)
            let service = CursorWebAuthService(
                session: session,
                pollIntervalNanoseconds: 1,
                maxPollAttempts: 1
            )

            MockURLProtocol.handler = { request in
                let body = try JSONSerialization.data(withJSONObject: [
                    "error": unsafeErrorCode,
                    "error_description": "authorization: Bearer cursor-secret",
                ])
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    body
                )
            }

            do {
                _ = try await service.signIn { _ in true }
                XCTFail("Expected Cursor sign-in to fail.")
            } catch {
                XCTAssertEqual(
                    error as? CursorWebAuthService.AuthError,
                    .tokenPollFailed("Token endpoint rejected the request.")
                )
                XCTAssertFalse(error.localizedDescription.contains("cursor-secret"))
            }
        }
    }

    @MainActor
    func testCursorBrowserSignInKeepsPendingAuthorizationActionable() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 2
        )
        var requestCount = 0

        MockURLProtocol.handler = { request in
            requestCount += 1
            let statusCode = requestCount == 1 ? 404 : 200
            let body = requestCount == 1
                ? Data(#"{"error":"authorization_pending","error_description":"keep waiting"}"#.utf8)
                : Data(#"{"accessToken":"cursor-access"}"#.utf8)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                body
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await service.signIn { _ in true }

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.accessToken, "cursor-access")
    }

    @MainActor
    func testCursorBrowserSignInPreservesSafeExpiredCode() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )

        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"error":"expired_token","error_description":"authorization: Bearer cursor-secret"}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        do {
            _ = try await service.signIn { _ in true }
            XCTFail("Expected Cursor sign-in to fail.")
        } catch {
            XCTAssertEqual(
                error as? CursorWebAuthService.AuthError,
                .tokenPollFailed("expired_token")
            )
            XCTAssertFalse(error.localizedDescription.contains("cursor-secret"))
        }
    }

#if canImport(AuthenticationServices) && canImport(AppKit)
    @MainActor
    func testCursorBrowserSessionUsesEphemeralStorage() {
        let session = CursorWebAuthenticationPresenter.makeSession(
            url: URL(string: "https://cursor.com/loginDeepControl")!
        ) { _ in }

        XCTAssertTrue(session.prefersEphemeralWebBrowserSession)
    }
#endif

    func testCursorBrowserSessionIgnoresStaleCompletionAfterRetry() {
        var generation = CursorWebAuthenticationSessionGeneration()
        let firstSessionID = generation.start()
        let retrySessionID = generation.start()

        XCTAssertFalse(generation.complete(firstSessionID))
        XCTAssertTrue(generation.complete(retrySessionID))
        XCTAssertFalse(generation.complete(retrySessionID))
    }

    func testCursorNormalizesPastedAuthJSONAndBearerHeader() {
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: #"{"accessToken":"cursor-token","refreshToken":"refresh"}"#),
            "cursor-token"
        )
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: "Authorization: Bearer cursor-token"),
            "cursor-token"
        )
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: "\"cursor-quoted\""),
            "cursor-quoted"
        )
    }

    func testCursorUsageParserReadsDashboardUsage() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        configuration.accountLabel = "Cursor Pro"
        let payload = """
        {
          "billingCycleStart": "1783036800000",
          "billingCycleEnd": "1784332800000",
          "planUsage": {
            "autoPercentUsed": 42.4,
            "apiPercentUsed": 18.2,
            "totalPercentUsed": 62.6
          },
          "spendLimitUsage": {
            "individualLimit": 2000,
            "individualRemaining": 800
          }
        }
        """

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.title, "Cursor Pro")
        XCTAssertEqual(
            result.subtitle,
            "Included usage - Cursor Models 42% - Other Models 18%"
        )
        XCTAssertEqual(result.bars.map(\.label), [
            "Cursor Models",
            "Other Models",
            "On-demand $12.00 / $20.00",
        ])
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "cursor-models",
            "other-models",
            "on-demand",
        ])
        XCTAssertFalse(result.hasReachedSpendLimit)
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "18%", "60%"])
        XCTAssertTrue(result.bars.allSatisfy(\.showProjectionOnCurrentBar))
        XCTAssertEqual(
            result.bars.compactMap(\.projectionPeriodStart),
            Array(repeating: Date(timeIntervalSince1970: 1_783_036_800), count: 3)
        )
        XCTAssertEqual(
            result.bars.compactMap(\.projectionPeriodEnd),
            Array(repeating: Date(timeIntervalSince1970: 1_784_332_800), count: 3)
        )
        XCTAssertEqual(try XCTUnwrap(result.bars[0].projectionCurrent), 0.424, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.bars[1].projectionCurrent), 0.182, accuracy: 0.000_001)
        XCTAssertEqual(result.bars[2].projectionCurrent, 12)
        XCTAssertEqual(result.bars.compactMap(\.projectionLimit), [1, 1, 20])
        XCTAssertEqual(result.bars[0].projectionDescription(at: fetchedAt), "Projected to stay under limit")
        XCTAssertEqual(result.bars[1].projectionDescription(at: fetchedAt), "Projected to stay under limit")
        XCTAssertTrue(try XCTUnwrap(result.bars[2].projectionDescription(at: fetchedAt)).hasPrefix(
            "Projected 100% at current pace - Limit hit "
        ))
    }

    func testCursorUsageParserPreservesOverLimitModelBuckets() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "billingCycleStart": "1783036800000",
          "billingCycleEnd": "1784332800000",
          "planUsage": {
            "autoPercentUsed": 137.4,
            "apiPercentUsed": 118
          }
        }
        """

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(payload.utf8),
            configuration: .defaultConfiguration(for: .cursor),
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.used), [137.4, 118])
        XCTAssertEqual(result.bars.map(\.usageText), ["137%", "118%"])
        XCTAssertEqual(result.bars.map(\.fractionUsed), [1, 1])
        let projectionCurrent = result.bars.compactMap(\.projectionCurrent)
        XCTAssertEqual(projectionCurrent.count, 2)
        XCTAssertEqual(projectionCurrent[0], 1.374, accuracy: 0.000_001)
        XCTAssertEqual(projectionCurrent[1], 1.18, accuracy: 0.000_001)
        XCTAssertEqual(
            result.subtitle,
            "Included usage - Cursor Models 137% - Other Models 118%"
        )

        let historySnapshot = UsageHistorySnapshot(result: result)
        XCTAssertEqual(historySnapshot.bars.map(\.used), [137.4, 118])
        XCTAssertEqual(
            try XCTUnwrap(historySnapshot.primaryValue),
            1.374,
            accuracy: 0.000_001
        )
    }

    func testCursorUsageParserHandlesIndependentMissingBoundaryAndMalformedBuckets() throws {
        let fixtures: [(payload: String, labels: [String], usage: [String])] = [
            (
                #"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":100,"totalPercentUsed":99}}"#,
                ["Cursor Models", "Other Models"],
                ["0%", "100%"]
            ),
            (
                #"{"planUsage":{"apiPercentUsed":37.4}}"#,
                ["Other Models"],
                ["37%"]
            ),
            (
                #"{"planUsage":{"autoPercentUsed":"invalid","apiPercentUsed":24}}"#,
                ["Other Models"],
                ["24%"]
            ),
            (
                #"{"planUsage":{"autoPercentUsed":-5,"apiPercentUsed":1e100}}"#,
                ["Cursor Models"],
                ["0%"]
            ),
        ]

        for fixture in fixtures {
            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                Data(fixture.payload.utf8),
                configuration: .defaultConfiguration(for: .cursor)
            ))
            XCTAssertEqual(result.bars.map(\.label), fixture.labels)
            XCTAssertEqual(result.bars.map(\.usageText), fixture.usage)
        }

        XCTAssertNil(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":{"totalPercentUsed":99}}"#.utf8),
            configuration: .defaultConfiguration(for: .cursor)
        ))
    }

    func testCursorUsageParserMarksSpendLimitReached() throws {
        let payload = """
        {
          "billingCycleStart": "1783036800000",
          "billingCycleEnd": "1784332800000",
          "spendLimitUsage": {
            "individualLimit": 2000,
            "individualRemaining": 0
          }
        }
        """

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(payload.utf8),
            configuration: .defaultConfiguration(for: .cursor)
        ))

        XCTAssertTrue(result.hasReachedSpendLimit)
        XCTAssertEqual(result.highestSeverity, .critical)
    }

    func testCursorUsageParserReadsGrokBotWeeklyPeriods() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_787_443_200)
        let usagePayload = Data(#"{"planUsage":{"autoPercentUsed":25}}"#.utf8)
        let iso8601Payload = Data("""
        {
          "currentPeriodStart": "2026-08-19T21:37:33.239Z",
          "nextResetTimestampUtc": "2026-08-26T21:37:33.239Z",
          "usagePercent": 38.059383,
          "usesPooledEnterpriseAllowance": false
        }
        """.utf8)

        let iso8601Result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            usagePayload,
            grokBotUsageData: iso8601Payload,
            configuration: .defaultConfiguration(for: .cursor),
            fetchedAt: fetchedAt
        ))
        let iso8601Bar = try XCTUnwrap(iso8601Result.bars.last)

        XCTAssertEqual(iso8601Result.bars.map(\.label), ["Cursor Models", "Grok Bot weekly"])
        XCTAssertEqual(iso8601Bar.stableKey, "grok-bot-weekly")
        XCTAssertEqual(iso8601Bar.usageText, "38%")
        XCTAssertEqual(
            try XCTUnwrap(iso8601Bar.resetsAt).timeIntervalSince1970,
            1_787_780_253.239,
            accuracy: 0.001
        )
        XCTAssertTrue(iso8601Bar.showProjectionOnCurrentBar)

        let millisecondPayload = Data("""
        {
          "current_period_start": "1787184000000",
          "next_reset_timestamp_utc": "1787788800000",
          "usage_percent": 7.5
        }
        """.utf8)
        let millisecondResult = try XCTUnwrap(CursorUsageProvider.parseUsage(
            usagePayload,
            grokBotUsageData: millisecondPayload,
            configuration: .defaultConfiguration(for: .cursor),
            fetchedAt: fetchedAt
        ))
        let millisecondBar = try XCTUnwrap(millisecondResult.bars.last)
        XCTAssertEqual(millisecondBar.used, 7.5)
        XCTAssertEqual(
            try XCTUnwrap(millisecondBar.projectionPeriodStart).timeIntervalSince1970,
            1_787_184_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(millisecondBar.projectionPeriodEnd).timeIntervalSince1970,
            1_787_788_800,
            accuracy: 0.001
        )
    }

    func testCursorUsageParserClampsAndOmitsUnavailableGrokBotUsage() throws {
        let usagePayload = Data(#"{"planUsage":{"autoPercentUsed":25}}"#.utf8)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)

        for (percent, expected) in [(-10.0, 0.0), (125.0, 100.0)] {
            let payload = Data(#"{"usagePercent":\#(percent)}"#.utf8)
            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                usagePayload,
                grokBotUsageData: payload,
                configuration: configuration
            ))
            XCTAssertEqual(result.bars.last?.used, expected)
        }

        let omittedPayloads = [
            Data(#"{"usage_percent":38,"uses_pooled_enterprise_allowance":true}"#.utf8),
            Data(#"{"usagePercent":"NaN"}"#.utf8),
            Data(#"{"usagePercent":38"#.utf8),
        ]
        for payload in omittedPayloads {
            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                usagePayload,
                grokBotUsageData: payload,
                configuration: configuration
            ))
            XCTAssertEqual(result.bars.map(\.label), ["Cursor Models"])
        }
    }

    func testCursorUsageParserOmitsGrokBotUsageWithoutIncludedAllowance() throws {
        let usagePayload = Data(#"{"planUsage":{"autoPercentUsed":25}}"#.utf8)
        let unavailablePayloads = [
            #"{"usagePercent":0,"hasNonZeroIncludedLimit":false}"#,
            #"{"usage_percent":0,"has_non_zero_included_limit":false}"#,
            #"{"usagePercent":0,"hasNonzeroIncludedLimit":false}"#,
            #"{"usage_percent":0,"has_nonzero_included_limit":false}"#,
            #"{"usagePercent":0,"includedLimitZero":true}"#,
            #"{"usage_percent":0,"included_limit_zero":true}"#,
        ]

        for grokBotPayload in unavailablePayloads {
            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                usagePayload,
                grokBotUsageData: Data(grokBotPayload.utf8),
                configuration: .defaultConfiguration(for: .cursor)
            ))

            XCTAssertEqual(result.bars.map(\.label), ["Cursor Models"])
            XCTAssertEqual(result.bars.map(\.stableKey), ["cursor-models"])
        }
    }

    func testCursorUsageParserKeepsEntitledZeroPercentGrokBotUsage() throws {
        let usagePayload = Data(#"{"planUsage":{"autoPercentUsed":25}}"#.utf8)
        let grokBotPayload = Data("""
        {
          "usagePercent": 0,
          "hasNonZeroIncludedLimit": true,
          "includedLimitZero": false,
          "usesPooledEnterpriseAllowance": false
        }
        """.utf8)

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            usagePayload,
            grokBotUsageData: grokBotPayload,
            configuration: .defaultConfiguration(for: .cursor)
        ))

        XCTAssertEqual(result.bars.map(\.label), ["Cursor Models", "Grok Bot weekly"])
        XCTAssertEqual(result.bars.last?.usageText, "0%")
    }

    func testCursorUsageParserSuppressesGrokBotProjectionOutsideCurrentPeriod() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_787_443_200)
        let usagePayload = Data(#"{"planUsage":{"autoPercentUsed":25}}"#.utf8)
        let invalidPeriods = [
            #"{"usagePercent":38,"nextResetTimestampUtc":"2026-08-26T21:37:33Z"}"#,
            #"{"usagePercent":38,"currentPeriodStart":"2026-08-24T21:37:33Z","nextResetTimestampUtc":"2026-08-31T21:37:33Z"}"#,
            #"{"usagePercent":38,"currentPeriodStart":"2026-08-12T21:37:33Z","nextResetTimestampUtc":"2026-08-19T21:37:33Z"}"#,
        ]

        for payload in invalidPeriods {
            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                usagePayload,
                grokBotUsageData: Data(payload.utf8),
                configuration: .defaultConfiguration(for: .cursor),
                fetchedAt: fetchedAt
            ))
            let grokBotBar = try XCTUnwrap(result.bars.last)
            XCTAssertFalse(grokBotBar.showProjectionOnCurrentBar)
            XCTAssertNil(grokBotBar.projectionPeriodStart)
            XCTAssertNil(grokBotBar.projectionPeriodEnd)
        }
    }

    func testCursorUsageParserSuppressesPredictionsWithoutValidCurrentBillingPeriod() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let invalidPeriods = [
            #""billingCycleEnd": "1784332800000","#,
            #""billingCycleStart": "invalid", "billingCycleEnd": "1784332800000","#,
            #""billingCycleStart": "1784332800000", "billingCycleEnd": "1781740800000","#,
            #""billingCycleStart": "1784332800000", "billingCycleEnd": "1786924800000","#,
        ]

        for periodFields in invalidPeriods {
            let payload = """
            {
              \(periodFields)
              "planUsage": {
                "autoPercentUsed": 10,
                "apiPercentUsed": 5,
                "totalPercentUsed": 25
              },
              "spendLimitUsage": {
                "individualLimit": 2000,
                "individualRemaining": 1500
              }
            }
            """

            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                Data(payload.utf8),
                configuration: .defaultConfiguration(for: .cursor),
                fetchedAt: fetchedAt
            ))

            XCTAssertEqual(result.bars.count, 3)
            XCTAssertTrue(result.bars.allSatisfy { !$0.showProjectionOnCurrentBar })
            XCTAssertTrue(result.bars.allSatisfy { $0.projectionDescription(at: fetchedAt) == nil })
        }
    }

    func testCursorProviderFetchesDashboardUsage() async throws {
        let secretStore = InMemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        configuration.accountLabel = "Cursor"
        try secretStore.saveSecret(
            #"{"accessToken":"cursor-token"}"#,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = CursorUsageProvider(secretStore: secretStore, session: session)
        let currentUsageRequest = expectation(description: "Current Cursor usage requested")
        let grokBotUsageRequest = expectation(description: "Grok Bot usage requested")

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cursor-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(requestBodyData(from: request), Data("{}".utf8))
            let responseData: Data
            switch request.url?.lastPathComponent {
            case "GetCurrentPeriodUsage":
                currentUsageRequest.fulfill()
                responseData = Data(
                    #"{"planUsage":{"totalPercentUsed":25,"autoPercentUsed":10,"apiPercentUsed":5}}"#.utf8
                )
            case "GetSandUsageStatus":
                grokBotUsageRequest.fulfill()
                responseData = Data(#"{"usagePercent":12.4}"#.utf8)
            default:
                XCTFail("Unexpected Cursor usage URL: \(request.url?.absoluteString ?? "nil")")
                responseData = Data()
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                responseData
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)
        await fulfillment(of: [currentUsageRequest, grokBotUsageRequest], timeout: 1)

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.title, "Cursor")
        XCTAssertEqual(
            result.bars.map(\.label),
            ["Cursor Models", "Other Models", "Grok Bot weekly"]
        )
        XCTAssertEqual(result.bars.first?.usageText, "10%")
    }

    func testCursorProviderKeepsPlanUsageWhenOptionalGrokBotRequestFails() async throws {
        let outcomes: [(statusCode: Int?, data: Data)] = [
            (nil, Data()),
            (503, Data(#"{"usagePercent":12}"#.utf8)),
            (200, Data(#"{"usagePercent":12"#.utf8)),
        ]

        for outcome in outcomes {
            let secretStore = InMemorySecretStore()
            let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
            try secretStore.saveSecret(
                "cursor-token",
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
            let urlSessionConfiguration = URLSessionConfiguration.ephemeral
            urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: urlSessionConfiguration)
            let provider = CursorUsageProvider(secretStore: secretStore, session: session)

            MockURLProtocol.handler = { request in
                guard request.url?.lastPathComponent == "GetSandUsageStatus" else {
                    return (
                        HTTPURLResponse(
                            url: try XCTUnwrap(request.url), statusCode: 200,
                            httpVersion: nil, headerFields: nil
                        )!,
                        Data(#"{"planUsage":{"autoPercentUsed":25}}"#.utf8)
                    )
                }
                guard let statusCode = outcome.statusCode else {
                    throw URLError(.cannotConnectToHost)
                }
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url), statusCode: statusCode,
                        httpVersion: nil, headerFields: nil
                    )!,
                    outcome.data
                )
            }

            let result = try await provider.fetchUsage(for: configuration)
            session.invalidateAndCancel()
            XCTAssertEqual(result.bars.map(\.label), ["Cursor Models"])
        }
        MockURLProtocol.handler = nil
    }

    func testCursorProviderDoesNotRequestHiddenGrokBotUsage() async throws {
        let secretStore = InMemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        configuration.showsCursorGrokBotWeekly = false
        try secretStore.saveSecret(
            "cursor-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = CursorUsageProvider(secretStore: secretStore, session: session)
        var grokBotRequestCount = 0

        MockURLProtocol.handler = { request in
            if request.url?.lastPathComponent == "GetSandUsageStatus" {
                grokBotRequestCount += 1
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url), statusCode: 200,
                    httpVersion: nil, headerFields: nil
                )!,
                Data(#"{"planUsage":{"autoPercentUsed":25}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(grokBotRequestCount, 0)
        XCTAssertEqual(result.bars.map(\.label), ["Cursor Models"])
    }

    func testCursorProviderDoesNotWaitForStalledOptionalGrokBotUsage() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        try secretStore.saveSecret(
            "cursor-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [StalledCursorGrokBotURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        defer { session.invalidateAndCancel() }
        let provider = CursorUsageProvider(
            secretStore: secretStore,
            session: session,
            grokBotRequestTimeout: .milliseconds(25)
        )

        let result = try await withTestWatchdog(
            timeout: .seconds(1),
            failureMessage: "Cursor usage waited for the stalled optional Grok Bot request.",
            onTimeout: {},
            operation: { try await provider.fetchUsage(for: configuration) }
        )

        XCTAssertEqual(result.bars.map(\.label), ["Cursor Models"])
        XCTAssertEqual(result.bars.first?.usageText, "25%")
    }

    func testCursorProviderReadsLocalAuthFileWhenKeychainIsEmpty() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let authPath = temporaryDirectory.appendingPathComponent("auth.json").path
        try Data(#"{"accessToken":"local-cursor-token"}"#.utf8).write(to: URL(fileURLWithPath: authPath))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = CursorUsageProvider(
            secretStore: InMemorySecretStore(),
            session: session,
            authFilePath: authPath
        )

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-cursor-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"planUsage":{"totalPercentUsed":12,"autoPercentUsed":4,"apiPercentUsed":2}}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .cursor))

        XCTAssertEqual(result.bars.first?.usageText, "4%")
    }

    func testCursorProviderDoesNotUseLocalAuthFileForAdditionalAccount() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let authPath = temporaryDirectory.appendingPathComponent("auth.json").path
        try Data(#"{"accessToken":"local-cursor-token"}"#.utf8).write(to: URL(fileURLWithPath: authPath))
        let configuration = ProviderAccountConfiguration(
            id: "cursor.additional",
            providerID: .cursor,
            authMethod: .browserSession
        )
        let provider = CursorUsageProvider(
            secretStore: InMemorySecretStore(),
            authFilePath: authPath
        )

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with Cursor.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCursorProviderKeepsSavedBrowserSessionsIsolated() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let authPath = temporaryDirectory.appendingPathComponent("auth.json").path
        try Data(#"{"accessToken":"local-cursor-token"}"#.utf8).write(to: URL(fileURLWithPath: authPath))

        let first = ProviderAccountConfiguration(
            id: "cursor.first",
            providerID: .cursor,
            authMethod: .browserSession
        )
        let second = ProviderAccountConfiguration(
            id: "cursor.second",
            providerID: .cursor,
            authMethod: .browserSession
        )
        let secretStore = InMemorySecretStore()
        try secretStore.saveSecret(
            #"{"accessToken":"first-cursor-token"}"#,
            account: ProviderConfigurationStore.keychainAccount(for: first)
        )
        try secretStore.saveSecret(
            #"{"accessToken":"second-cursor-token"}"#,
            account: ProviderConfigurationStore.keychainAccount(for: second)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = CursorUsageProvider(
            secretStore: secretStore,
            session: session,
            authFilePath: authPath
        )
        defer {
            MockURLProtocol.handler = nil
        }

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer first-cursor-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"planUsage":{"autoPercentUsed":11}}"#.utf8)
            )
        }
        let firstResult = try await provider.fetchUsage(for: first)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer second-cursor-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"planUsage":{"autoPercentUsed":22}}"#.utf8)
            )
        }
        let secondResult = try await provider.fetchUsage(for: second)

        XCTAssertEqual(firstResult.accountID, first.id)
        XCTAssertEqual(firstResult.bars.first?.usageText, "11%")
        XCTAssertEqual(secondResult.accountID, second.id)
        XCTAssertEqual(secondResult.bars.first?.usageText, "22%")
    }

    func testCursorProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = CursorUsageProvider(secretStore: InMemorySecretStore(), authFilePath: "/tmp/missing-cursor-auth.json")
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with Cursor.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCursorProviderRejectedSessionShowsReauthPrompt() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        try secretStore.saveSecret(
            #"{"accessToken":"expired-token"}"#,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = CursorUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data("{}".utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.subtitle, "Cursor rejected this session token. Sign in again.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCursorCredentialsParserReadsAuthFile() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let authPath = temporaryDirectory.appendingPathComponent("auth.json").path
        try Data(#"{"accessToken":"redacted-token","refreshToken":"redacted-refresh"}"#.utf8)
            .write(to: URL(fileURLWithPath: authPath))

        let credentials = try XCTUnwrap(CursorCredentialsParser.parseAuthFile(at: authPath))
        XCTAssertEqual(credentials.accessToken, "redacted-token")
        XCTAssertTrue(CursorCredentialsParser.hasSession(at: authPath))
    }

}

private final class StalledCursorGrokBotURLProtocol: URLProtocol, @unchecked Sendable {
    // URLProtocol requires overridable class methods.
    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    // URLProtocol requires overridable class methods.
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard request.url?.lastPathComponent == "GetCurrentPeriodUsage" else {
            return
        }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"planUsage":{"autoPercentUsed":25}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
