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
        XCTAssertEqual(result.subtitle, "Included usage - Auto 42% - API 18%")
        XCTAssertEqual(result.bars.map(\.label), [
            "Total",
            "Auto",
            "API",
            "On-demand $12.00 / $20.00",
        ])
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "total",
            "auto",
            "api",
            "on-demand",
        ])
        XCTAssertFalse(result.hasReachedSpendLimit)
        XCTAssertEqual(result.bars.map(\.usageText), ["63%", "42%", "18%", "60%"])
        XCTAssertTrue(result.bars.allSatisfy(\.showProjectionOnCurrentBar))
        XCTAssertEqual(
            result.bars.compactMap(\.projectionPeriodStart),
            Array(repeating: Date(timeIntervalSince1970: 1_783_036_800), count: 4)
        )
        XCTAssertEqual(
            result.bars.compactMap(\.projectionPeriodEnd),
            Array(repeating: Date(timeIntervalSince1970: 1_784_332_800), count: 4)
        )
        XCTAssertEqual(try XCTUnwrap(result.bars[0].projectionCurrent), 0.626, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.bars[1].projectionCurrent), 0.424, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.bars[2].projectionCurrent), 0.182, accuracy: 0.000_001)
        XCTAssertEqual(result.bars[3].projectionCurrent, 12)
        XCTAssertEqual(result.bars.compactMap(\.projectionLimit), [1, 1, 1, 20])
        XCTAssertTrue(try XCTUnwrap(result.bars[0].projectionDescription(at: fetchedAt)).hasPrefix(
            "Projected 100% at current pace - Limit hit "
        ))
        XCTAssertEqual(result.bars[2].projectionDescription(at: fetchedAt), "Projected to stay under limit")
        XCTAssertTrue(try XCTUnwrap(result.bars[3].projectionDescription(at: fetchedAt)).hasPrefix(
            "Projected 100% at current pace - Limit hit "
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

            XCTAssertEqual(result.bars.count, 4)
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

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cursor-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
            XCTAssertEqual(requestBodyData(from: request), Data("{}".utf8))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"planUsage":{"totalPercentUsed":25,"autoPercentUsed":10,"apiPercentUsed":5}}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.title, "Cursor")
        XCTAssertEqual(result.bars.map(\.label), ["Total", "Auto", "API"])
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

        XCTAssertEqual(result.bars.first?.usageText, "12%")
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
