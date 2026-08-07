import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class CopilotProviderTests: XCTestCase {
    deinit {}

    func testCopilotCredentialsParserReadsStoredJSONAndRawToken() {
        XCTAssertEqual(
            CopilotCredentialsParser.parse(#"{"accessToken":"token","username":"octocat"}"#),
            CopilotCredentials(accessToken: "token", username: "octocat")
        )
        XCTAssertEqual(
            CopilotCredentialsParser.parse("gho_raw_token"),
            CopilotCredentials(accessToken: "gho_raw_token")
        )
    }

    func testCopilotBrowserAuthorizationUsesPKCEAndRegisteredLoopbackRedirect() throws {
        let url = CopilotWebAuthService.authorizationURL(
            clientID: "client-id",
            redirectURI: "http://127.0.0.1:1456/callback",
            state: "state-value",
            codeChallenge: "challenge-value"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/login/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "client_id"), "client-id")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://127.0.0.1:1456/callback")
        XCTAssertEqual(components.queryItemValue(named: "scope"), "read:org")
        XCTAssertEqual(components.queryItemValue(named: "state"), "state-value")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge"), "challenge-value")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "prompt"), "select_account")
    }

    @MainActor
    func testCopilotBrowserSignInUsesIPv4LoopbackAndTimesOut() async throws {
        let service = CopilotWebAuthService(callbackTimeoutNanoseconds: 10_000_000)
        var presentedURL: URL?

        do {
            _ = try await service.signIn(
                configuration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret")
            ) { url in
                presentedURL = url
                return true
            }
            XCTFail("Expected GitHub browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? CopilotWebAuthService.AuthError, .callbackTimedOut)
        }

        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(components.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "127.0.0.1")
    }

    @MainActor
    func testCopilotBrowserSignInExchangesCallbackForCredentials() async throws {
        let responseBody = Data(
            #"{"access_token":"redacted-access-token","refresh_token":"redacted-refresh-token","expires_in":3600,"refresh_token_expires_in":7200}"#.utf8
        )
        let startedAt = Int64(Date().timeIntervalSince1970)

        let result = try await performCopilotTokenExchange(responseBody: responseBody) { request, authorizationURL in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded"
            )
            let authorization = try XCTUnwrap(
                URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
            )
            let redirectURI = try XCTUnwrap(authorization.queryItemValue(named: "redirect_uri"))
            XCTAssertEqual(authorization.queryItemValue(named: "client_id"), "redacted-client-id")
            XCTAssertEqual(authorization.queryItemValue(named: "state"), deterministicOAuthValue(byteCount: 32))
            XCTAssertEqual(URL(string: redirectURI)?.host, "127.0.0.1")
            XCTAssertEqual(URL(string: redirectURI)?.path, "/callback")

            let body = try formValues(from: requestBodyData(from: request))
            XCTAssertEqual(body["client_id"], "redacted-client-id")
            XCTAssertEqual(body["client_secret"], "redacted-client-secret")
            XCTAssertEqual(body["code"], syntheticOAuthCode)
            XCTAssertEqual(body["redirect_uri"], redirectURI)
            XCTAssertEqual(body["code_verifier"], deterministicOAuthValue(byteCount: 64))
        }

        let completedAt = Int64(Date().timeIntervalSince1970)
        XCTAssertEqual(result.accessToken, "redacted-access-token")
        XCTAssertEqual(result.refreshToken, "redacted-refresh-token")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.expiresAt), startedAt + 3_599)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.expiresAt), completedAt + 3_600)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.refreshTokenExpiresAt), startedAt + 7_199)
        XCTAssertLessThanOrEqual(try XCTUnwrap(result.refreshTokenExpiresAt), completedAt + 7_200)
    }

    @MainActor
    func testCopilotBrowserSignInSanitizesNonSuccessTokenResponse() async throws {
        let responseBody = Data(
            #"{"error":"invalid_grant","error_description":"redacted-authorization-code redacted-access-token untrusted detail"}"#.utf8
        )

        do {
            _ = try await performCopilotTokenExchange(statusCode: 400, responseBody: responseBody)
            XCTFail("Expected a rejected GitHub token exchange.")
        } catch {
            XCTAssertEqual(
                error as? CopilotWebAuthService.AuthError,
                .tokenExchangeFailed("HTTP 400 (invalid_grant)")
            )
            XCTAssertFalse(error.localizedDescription.contains(syntheticOAuthCode))
            XCTAssertFalse(error.localizedDescription.contains("redacted-access-token"))
            XCTAssertFalse(error.localizedDescription.contains("untrusted detail"))
        }
    }

    @MainActor
    func testCopilotBrowserSignInRejectsMalformedSuccessResponse() async throws {
        do {
            _ = try await performCopilotTokenExchange(responseBody: Data(#"{"access_token":42}"#.utf8))
            XCTFail("Expected a malformed GitHub token response to fail.")
        } catch {
            XCTAssertEqual(error as? CopilotWebAuthService.AuthError, .invalidTokenResponse)
        }
    }

    @MainActor
    func testCopilotBrowserSignInRejectsSuccessResponseWithoutAccessToken() async throws {
        do {
            _ = try await performCopilotTokenExchange(
                responseBody: Data(#"{"refresh_token":"redacted-refresh-token"}"#.utf8)
            )
            XCTFail("Expected a GitHub token response without an access token to fail.")
        } catch {
            XCTAssertEqual(error as? CopilotWebAuthService.AuthError, .invalidTokenResponse)
            XCTAssertFalse(error.localizedDescription.contains("redacted-refresh-token"))
        }
    }

    @MainActor
    func testCopilotBrowserSignInSurfacesOnlySafeOAuthErrorCode() async throws {
        let responseBody = Data(
            #"{"error":"access_denied","error_description":"redacted-authorization-code untrusted denial"}"#.utf8
        )

        do {
            _ = try await performCopilotTokenExchange(responseBody: responseBody)
            XCTFail("Expected an OAuth error payload to fail GitHub sign-in.")
        } catch {
            XCTAssertEqual(
                error as? CopilotWebAuthService.AuthError,
                .tokenExchangeFailed("access_denied")
            )
            XCTAssertFalse(error.localizedDescription.contains(syntheticOAuthCode))
            XCTAssertFalse(error.localizedDescription.contains("untrusted denial"))
        }
    }

    func testCopilotOAuthRequestBodiesUseFormEncoding() {
        let tokenBody = String(
            data: CopilotWebAuthService.makeTokenRequestBody(
                clientID: "client",
                clientSecret: "secret",
                code: "code value",
                redirectURI: "http://127.0.0.1:1456/callback",
                codeVerifier: "verifier value"
            ),
            encoding: .utf8
        )
        XCTAssertEqual(
            tokenBody,
            "client_id=client&client_secret=secret&code=code%20value&redirect_uri=http%3A%2F%2F127.0.0.1%3A1456%2Fcallback&code_verifier=verifier%20value"
        )

        let refreshBody = String(
            data: CopilotWebAuthService.makeRefreshTokenRequestBody(
                clientID: "client",
                clientSecret: "secret",
                refreshToken: "refresh value"
            ),
            encoding: .utf8
        )
        XCTAssertEqual(
            refreshBody,
            "client_id=client&client_secret=secret&grant_type=refresh_token&refresh_token=refresh%20value"
        )
    }

    func testCopilotWebAuthResultStoresRefreshableCredential() throws {
        let stored = CopilotWebAuthResult(
            accessToken: "redacted-access",
            refreshToken: "redacted-refresh",
            expiresAt: 2_000_000_000,
            refreshTokenExpiresAt: 2_100_000_000
        ).storedCredential(username: "octocat")
        let parsed = try XCTUnwrap(CopilotCredentialsParser.parse(stored))

        XCTAssertEqual(parsed.accessToken, "redacted-access")
        XCTAssertEqual(parsed.refreshToken, "redacted-refresh")
        XCTAssertEqual(parsed.username, "octocat")
        XCTAssertEqual(parsed.expiresAt, 2_000_000_000)
        XCTAssertEqual(parsed.refreshTokenExpiresAt, 2_100_000_000)
    }

    func testCopilotUsageRequestMatchesWindowsCopilotHeaders() {
        let provider = CopilotUsageProvider(
            secretStore: InMemorySecretStore(),
            usageEndpoint: URL(string: "https://api.github.com/copilot_internal/user")!
        )

        let request = provider.makeUsageRequest(accessToken: "github-token")

        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/copilot_internal/user")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitHubCopilotChat/0.26.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Version"), "vscode/1.96.2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Plugin-Version"), "copilot-chat/0.26.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Github-Api-Version"), "2025-04-01")
    }

    func testCopilotUsageParserReadsQuotaSnapshots() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "quota_reset_date_utc": "2030-01-03T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            },
            "chat": {
              "entitlement": 100,
              "remaining": 12,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.providerID, .copilot)
        XCTAssertEqual(result.title, "GitHub Copilot (octocat) - Pro")
        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (1,500 / 2,000)", "Chat (88 / 100)"])
        XCTAssertEqual(result.bars.map(\.usageText), ["75%", "88%"])
        XCTAssertEqual(result.subtitle, "Resets in 3d")
    }

    func testCopilotUsageParserOmitsUnlimitedChatQuota() throws {
        let payload = """
        {
          "login": "fphemmer",
          "copilot_plan": "business",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            },
            "chat": {
              "entitlement": 0,
              "remaining": 0,
              "unlimited": true
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (1,500 / 2,000)"])
    }

    func testCopilotUsageParserToleratesSparseUnlimitedChatSnapshot() throws {
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "business",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            },
            "chat": {
              "unlimited": true
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (1,500 / 2,000)"])
    }

    func testCopilotUsageParserAcceptsFractionalResetTimestamps() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "quota_reset_date_utc": "2030-01-03T00:00:00.000Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.subtitle, "Resets in 3d")
        XCTAssertEqual(result.bars.first?.resetsAt, Date(timeIntervalSince1970: 1_893_628_800))
    }

    func testCopilotUsageParserFallsBackToDateOnlyResetField() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "quota_reset_date": "2030-01-03",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.subtitle, "Resets in 3d")
        XCTAssertEqual(result.bars.first?.resetsAt, Date(timeIntervalSince1970: 1_893_628_800))
    }

    func testCopilotUsageParserLabelsTokenBasedBillingAsAICredits() throws {
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "token_based_billing": true,
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 7000,
              "remaining": 4846,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.map(\.label), ["AI credits (2,154 / 7,000)"])
    }

    func testCopilotUsageParserUsesSnapshotBillingMarkerForAICredits() throws {
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "business",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 3000,
              "remaining": 2500,
              "unlimited": false,
              "token_based_billing": true
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.map(\.label), ["AI credits (500 / 3,000)"])
    }

    func testCopilotUsageParserKeepsPremiumInteractionsLabelForLegacyBilling() throws {
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "token_based_billing": false,
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 300,
              "remaining": 250,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (50 / 300)"])
    }

    func testCopilotUsageParserOmitsTokenBasedPlaceholderWithoutQuota() throws {
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "business",
          "token_based_billing": true,
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 0,
              "remaining": 0,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8)))

        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCopilotUsageParserSurfacesExhaustedPooledQuota() throws {
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "business",
          "token_based_billing": true,
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 0,
              "remaining": 0,
              "unlimited": true,
              "has_quota": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.map(\.label), ["AI credits - pool exhausted"])
        XCTAssertEqual(result.bars.first?.usageText, "100%")
    }

    func testCopilotUsageProviderPrefersKeychainWhenNoCLIUsernameBound() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "Saved Token",
            authMethod: .cliToken
        )
        try secretStore.saveSecret("saved-token", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            gitHubTokenResolver: { _ in
                XCTFail("Active CLI fallback should not run when a saved token exists")
                return "active-cli-token"
            }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token saved-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "login": "octocat",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 100,
                      "remaining": 40,
                      "unlimited": false
                    }
                  }
                }
                """.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 60)
    }

    func testCopilotBrowserCredentialRefreshesAndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "octocat",
            authMethod: .browserSession
        )
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                username: "octocat",
                refreshToken: "old-refresh",
                expiresAt: 2_000_000_060,
                refreshTokenExpiresAt: 2_100_000_000
            )),
            account: account
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/github-token" {
                XCTAssertEqual(request.timeoutInterval, 15)
                XCTAssertEqual(
                    String(data: try XCTUnwrap(requestBodyData(from: request)), encoding: .utf8),
                    "client_id=client&client_secret=secret&grant_type=refresh_token&refresh_token=old-refresh"
                )
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"refresh_token_expires_in":15897600}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token new-access")
            let persisted = try XCTUnwrap(
                CopilotCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: account)))
            )
            XCTAssertEqual(persisted.accessToken, "new-access")
            XCTAssertEqual(persisted.refreshToken, "new-refresh")
            XCTAssertEqual(persisted.username, "octocat")
            XCTAssertEqual(persisted.expiresAt, 2_000_028_800)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"login":"octocat","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testConcurrentCopilotFetchesCoalesceBrowserCredentialRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "copilot.concurrent-refresh",
            providerID: .copilot,
            accountLabel: "octocat",
            authMethod: .browserSession
        )
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                username: "octocat",
                refreshToken: "old-refresh",
                expiresAt: 2_000_000_060,
                refreshTokenExpiresAt: 2_100_000_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let refreshJoined = TestSignal()
        let refreshGate = CopilotRefreshRequestGate()
        let recorder = CopilotConcurrentRequestRecorder()
        let sessionFixture = IsolatedTestURLSession { request in
            if request.url?.path == "/github-token" {
                recorder.recordRefreshRequest()
                refreshGate.blockUntilReleased()
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"refresh_token_expires_in":15897600}"#.utf8)
                )
            }

            recorder.recordUsageRequest(
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer {
            refreshGate.release()
            sessionFixture.invalidate()
        }
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session,
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now },
            onJoinInFlightRefresh: { refreshJoined.signal() }
        )

        let results = try await withTestWatchdog(
            timeout: .seconds(10),
            failureMessage: "Copilot concurrent refresh did not finish within the test bound.",
            onTimeout: {
                refreshGate.release()
                sessionFixture.invalidate()
            }
        ) {
            let first = Task { try await provider.fetchUsage(for: configuration) }
            defer {
                first.cancel()
                refreshGate.release()
            }
            await refreshGate.waitUntilBlocked()

            let second = Task { try await provider.fetchUsage(for: configuration) }
            defer { second.cancel() }
            await refreshJoined.wait()

            refreshGate.release()
            return try await [first.value, second.value]
        }

        XCTAssertEqual(recorder.refreshRequestCount, 1)
        XCTAssertEqual(recorder.usageAuthorizations, ["token new-access", "token new-access"])
        XCTAssertTrue(results.allSatisfy { $0.bars.first?.used == 25 })
    }

    func testCopilotUsageProviderDoesNotCacheActiveCLIAccountToken() async throws {
        let tokenCounter = CopilotTokenResolverCounter()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            gitHubTokenResolver: { _ in tokenCounter.nextToken() }
        )
        MockURLProtocol.handler = { _ in
            (
                HTTPURLResponse(url: URL(string: "https://api.github.com/copilot_internal/user")!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "login": "octocat",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 100,
                      "remaining": 40,
                      "unlimited": false
                    }
                  }
                }
                """.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "Work",
            authMethod: .cliToken
        )
        _ = try await provider.fetchUsage(for: configuration)
        _ = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(tokenCounter.callCount, 2)
    }

    func testCopilotUsageProviderPrefersCLITokenOverStaleKeychainSecret() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "octocat",
            authMethod: .cliToken,
            githubCLIUsername: "octocat"
        )
        try secretStore.saveSecret("stale-token", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            gitHubTokenResolver: { _ in "github-token" }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "login": "octocat",
                  "copilot_plan": "individual_pro",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 2000,
                      "remaining": 1500,
                      "unlimited": false
                    }
                  }
                }
                """.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 500)
    }

    func testCopilotBrowserAccountPrefersBoundCLITokenOverKeychainCredential() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "octocat",
            authMethod: .browserSession,
            githubCLIUsername: "octocat"
        )
        try secretStore.saveSecret(
            "browser-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            gitHubTokenResolver: { username in
                XCTAssertEqual(username, "octocat")
                return "github-cli-token"
            }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-cli-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"login":"octocat","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":40,"unlimited":false}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 60)
    }

    func testCopilotUsageProviderFallsBackToKeychainSecretWhenCLIResolverFails() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "octocat",
            authMethod: .cliToken,
            githubCLIUsername: "octocat"
        )
        try secretStore.saveSecret("keychain-token", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            gitHubTokenResolver: { _ in nil }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token keychain-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "login": "octocat",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 100,
                      "remaining": 40,
                      "unlimited": false
                    }
                  }
                }
                """.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 60)
    }

    func testCopilotUsageProviderUsesStoredGitHubCLIUsernameWhenLabelChanges() async throws {
        let resolvedUsername = CopilotResolvedUsernameBox()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            gitHubTokenResolver: { username in
                resolvedUsername.value = username
                return "github-token"
            }
        )
        MockURLProtocol.handler = { request in
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "login": "octocat",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 100,
                      "remaining": 40,
                      "unlimited": false
                    }
                  }
                }
                """.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "Work",
            authMethod: .cliToken,
            githubCLIUsername: "octocat"
        )
        _ = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(resolvedUsername.value, "octocat")
    }

    func testLocalCredentialDiscoveryResolvesGitHubAuthToken() throws {
        let token = try XCTUnwrap(LocalCredentialDiscovery.gitHubAuthToken(for: "octocat") {
            (0, "gho_test_token\n", "")
        })

        XCTAssertEqual(token, "gho_test_token")
    }

    func testLocalCredentialDiscoveryResolvesActiveGitHubAuthToken() throws {
        let token = try XCTUnwrap(LocalCredentialDiscovery.gitHubAuthToken(for: nil) {
            (0, "gho_active_token\n", "")
        })

        XCTAssertEqual(token, "gho_active_token")
    }

    func testCopilotUsageProviderUsesActiveGitHubCLIAccountWhenUsernameMissing() async throws {
        let resolvedUsername = CopilotResolvedUsernameBox()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            gitHubTokenResolver: { username in
                resolvedUsername.value = username
                return "github-token"
            }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "login": "octocat",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 100,
                      "remaining": 40,
                      "unlimited": false
                    }
                  }
                }
                """.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "Work",
            authMethod: .cliToken
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertTrue(resolvedUsername.wasCalled)
        XCTAssertNil(resolvedUsername.value)
        XCTAssertEqual(result.bars.first?.used, 60)
    }

    func testCopilotUsageProviderReadsGitHubCLIToken() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            gitHubTokenResolver: { _ in "github-token" }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/copilot_internal/user")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "login": "octocat",
                  "copilot_plan": "individual_pro",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 2000,
                      "remaining": 1500,
                      "unlimited": false
                    }
                  }
                }
                """.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "octocat",
            authMethod: .cliToken,
            githubCLIUsername: "octocat"
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.title, "octocat")
        XCTAssertEqual(result.bars.first?.used, 500)
    }

    func testCopilotUsageProviderRetriesWithFreshGitHubCLITokenAfter401() async throws {
        let tokenCounter = CopilotTokenResolverCounter()
        var usageRequestCount = 0
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            gitHubTokenResolver: { _ in tokenCounter.nextToken() }
        )
        MockURLProtocol.handler = { request in
            usageRequestCount += 1
            if usageRequestCount == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token stale-token")
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token fresh-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("""
                {
                  "login": "octocat",
                  "quota_snapshots": {
                    "premium_interactions": {
                      "entitlement": 100,
                      "remaining": 40,
                      "unlimited": false
                    }
                  }
                }
                """.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            accountLabel: "octocat",
            authMethod: .cliToken,
            githubCLIUsername: "octocat"
        )
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(tokenCounter.callCount, 2)
        XCTAssertEqual(usageRequestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 60)
    }

    func testCopilotOrganizationBillingRequestSupportsStandaloneOrganization() throws {
        let provider = CopilotUsageProvider(
            secretStore: InMemorySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let date = Date(timeIntervalSince1970: 1_782_882_000)
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let request = try XCTUnwrap(provider.makeOrganizationBillingRequest(
            accessToken: "github-token",
            configuration: configuration,
            date: date
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/organizations/Relias-Engineering/settings/billing/ai_credit/usage")
        XCTAssertEqual(components.queryItemValue(named: "year"), "2026")
        XCTAssertEqual(components.queryItemValue(named: "month"), "7")
        XCTAssertEqual(components.queryItemValue(named: "product"), "Copilot")
        XCTAssertNil(components.queryItemValue(named: "organization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testCopilotOrganizationBillingRequestSupportsEnterpriseOrganization() throws {
        let provider = CopilotUsageProvider(
            secretStore: InMemorySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering",
            githubEnterprise: "bertelsmann"
        )

        let request = try XCTUnwrap(provider.makeOrganizationBillingRequest(
            accessToken: "github-token",
            configuration: configuration,
            date: Date(timeIntervalSince1970: 1_782_882_000)
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/enterprises/bertelsmann/settings/billing/ai_credit/usage")
        XCTAssertEqual(components.queryItemValue(named: "organization"), "Relias-Engineering")
    }

    func testCopilotOrganizationBillingRequestEncodesPathSeparatorsInOrgNames() throws {
        let provider = CopilotUsageProvider(
            secretStore: InMemorySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "Relias/Engineering",
            githubEnterprise: "berte/lsmann"
        )

        let request = try XCTUnwrap(provider.makeOrganizationBillingRequest(
            accessToken: "github-token",
            configuration: configuration,
            date: Date(timeIntervalSince1970: 1_782_882_000)
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.percentEncodedPath, "/enterprises/berte%2Flsmann/settings/billing/ai_credit/usage")
        XCTAssertTrue(try XCTUnwrap(request.url?.absoluteString).contains("berte%2Flsmann"))
        XCTAssertEqual(components.queryItemValue(named: "organization"), "Relias/Engineering")
    }

    func testCopilotOrganizationSeatCountRequestUsesOrgBillingEndpoint() throws {
        let provider = CopilotUsageProvider(
            secretStore: InMemorySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let request = try XCTUnwrap(provider.makeOrganizationSeatCountRequest(
            accessToken: "github-token",
            configuration: configuration
        ))

        XCTAssertEqual(request.url?.path, "/orgs/Relias-Engineering/copilot/billing")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testCopilotOrganizationCreditsPerSeatMatchesWindowsPromotionalWindow() {
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 6), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 7), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 8), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 9), 3_900)
        XCTAssertEqual(
            CopilotUsageProvider.creditsPerSeat(year: 2026, month: 7, planType: "business"),
            3_000
        )
        XCTAssertEqual(
            CopilotUsageProvider.creditsPerSeat(year: 2026, month: 9, planType: "business"),
            1_900
        )
        XCTAssertEqual(
            CopilotUsageProvider.creditsPerSeat(year: 2026, month: 7, planType: "enterprise"),
            7_000
        )
    }

    func testCopilotBillingUsageParserReadsOrganizationUsage() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "organization": "Relias-Engineering",
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1200 },
            { "product": "Actions", "sku": "Actions Linux", "grossQuantity": 99 },
            { "sku": "Copilot AI Credits", "grossQuantity": 300 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering",
            copilotTotalAllotment: 350000
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.accountID, "copilot.org")
        XCTAssertEqual(result.title, "Relias Engineering")
        XCTAssertEqual(result.subtitle, "Live GitHub Copilot usage for Relias-Engineering")
        XCTAssertEqual(result.bars.map(\.label), [
            "Current AI credits (1,500 / 350,000)",
        ])
        XCTAssertEqual(result.bars.map(\.usageText), ["0%"])
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 350000)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_782_864_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotBillingUsageParserProjectsOrganizationUsageWithoutAllotment() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1500 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.label), ["AI credits used (1,500)"])
        XCTAssertEqual(
            result.bars.first?.projectionDescription(at: fetchedAt),
            "Projected month end at current pace - 5,000 AI credits"
        )
    }

    func testCopilotBillingUsageParserUsesResolvedOrganizationPoolAllotment() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1500 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt,
            totalAllotment: 50 * 7_000
        ))

        XCTAssertEqual(result.bars.map(\.label), ["Current AI credits (1,500 / 350,000)"])
        XCTAssertEqual(result.bars.first?.usageText, "0%")
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 350000)
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotOrganizationUsageDistinguishesPermissionFailureFromMissingOrganization() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "HemSoft"
        )
        try secretStore.saveSecret(
            "legacy-access",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            githubAPIBaseURL: URL(string: "https://example.test")!,
            gitHubTokenResolver: { _ in nil }
        )
        var statusCode = 403
        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let permissionDenied = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(
            permissionDenied.subtitle,
            "This GitHub account lacks permission to read the configured Copilot organization billing data."
        )

        statusCode = 404
        let missingOrganization = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(
            missingOrganization.subtitle,
            "GitHub Copilot organization not found. Check the configured organization name."
        )

        let missingOrgConfiguration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .cliToken,
            copilotAccountScope: .organization
        )
        let notConfigured = try await provider.fetchUsage(for: missingOrgConfiguration)
        XCTAssertEqual(notConfigured.subtitle, "Not configured - enter organization.")
        XCTAssertFalse(notConfigured.isIncompleteRefresh)
    }

    func testCopilotOrganizationUsageResolvesSeatAllotmentAndParsesCredits() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Engineering",
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )
        try secretStore.saveSecret(
            "org-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            githubAPIBaseURL: URL(string: "https://example.test")!,
            gitHubTokenResolver: { _ in nil },
            now: { Date(timeIntervalSince1970: 1_783_667_520) }
        )
        MockURLProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/settings/billing/ai_credit/usage") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer org-token")
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"timePeriod":{"year":2026,"month":7},"usageItems":[{"product":"Copilot","sku":"Copilot AI Credits","grossQuantity":1500}]}"#.utf8)
                )
            }
            XCTAssertEqual(path, "/orgs/Relias-Engineering/copilot/billing")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"enterprise","seat_breakdown":{"total":50}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(result.bars.map(\.label), ["Current AI credits (1,500 / 350,000)"])
        XCTAssertEqual(result.subtitle, "Live GitHub Copilot usage for Relias-Engineering")
        XCTAssertFalse(result.subtitle.contains("not yet supported"))
    }

    func testCopilotOrganizationUsageUsesBusinessPlanSeatAllotment() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "copilot.biz",
            providerID: .copilot,
            accountLabel: "Business Org",
            authMethod: .cliToken,
            copilotAccountScope: .organization,
            githubOrganization: "HemSoft"
        )
        try secretStore.saveSecret(
            "org-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            githubAPIBaseURL: URL(string: "https://example.test")!,
            gitHubTokenResolver: { _ in nil },
            now: { Date(timeIntervalSince1970: 1_783_667_520) }
        )
        MockURLProtocol.handler = { request in
            let path = try XCTUnwrap(request.url?.path)
            if path.hasSuffix("/settings/billing/ai_credit/usage") {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"timePeriod":{"year":2026,"month":7},"usageItems":[{"product":"Copilot","sku":"Copilot AI Credits","grossQuantity":1500}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"business","seat_breakdown":{"total":50}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(result.bars.map(\.label), ["Current AI credits (1,500 / 150,000)"])
    }

}

private final class CopilotRefreshRequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let requestStarted = TestSignal()
    private var released = false

    deinit {}

    func blockUntilReleased() {
        condition.lock()
        requestStarted.signal()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked() async {
        await requestStarted.wait()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class CopilotConcurrentRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var refreshRequests = 0
    private var authorizations: [String?] = []

    deinit {}

    var refreshRequestCount: Int {
        lock.withLock { refreshRequests }
    }

    var usageAuthorizations: [String?] {
        lock.withLock { authorizations }
    }

    func recordRefreshRequest() {
        lock.withLock { refreshRequests += 1 }
    }

    func recordUsageRequest(authorization: String?) {
        lock.withLock { authorizations.append(authorization) }
    }
}
