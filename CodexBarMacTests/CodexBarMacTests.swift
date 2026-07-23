import XCTest
import Darwin
@testable import CodexBarMac

final class CodexBarMacTests: XCTestCase {
    func testSparkleConfigurationUsesSignedFeedAndDefaultConsentFlow() throws {
        let info = Bundle.main.infoDictionary ?? [:]

        XCTAssertEqual(
            info["SUFeedURL"] as? String,
            "https://hemsoft.github.io/codexbar-mac/appcast.xml"
        )
        XCTAssertEqual(
            info["SUPublicEDKey"] as? String,
            "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="
        )
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertNil(
            info["SUEnableAutomaticChecks"],
            "Sparkle must ask for automatic-check consent on its standard second-launch flow."
        )
    }

    func testCodexUsageParserReadsUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 81,
              "reset_at": 1894060800,
              "limit_window_seconds": 604800
            }
          }
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(
            Data(payload.utf8),
            fetchedAt: fetchedAt,
            dateTimeFormatter: formatter
        ))

        XCTAssertEqual(result.title, "ChatGPT / Codex (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "81%"])
        let resetDescription = try XCTUnwrap(result.bars.first?.resetDescription)
        XCTAssertTrue(resetDescription.hasPrefix("Resets 1d 0h (Tue 1:00"))
        XCTAssertTrue(resetDescription.hasSuffix("GMT+1)"))
        let newYorkFormatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: Locale(identifier: "en_US")
        )
        let reformattedReset = try XCTUnwrap(result.bars.first?.localizedResetDescription(
            at: fetchedAt,
            dateTimeFormatter: newYorkFormatter
        ))
        XCTAssertTrue(reformattedReset.hasSuffix("EST)"))
        XCTAssertFalse(reformattedReset.contains("GMT+1"))
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.42)
        XCTAssertEqual(result.bars.first?.projectionLimit, 1)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_893_438_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testCodexUsageParserSilentlyAcceptsMissingFiveHourWindowAndDurationDrift() throws {
        let weeklyOnlyPayload = #"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":30,"reset_at":1894060800,"limit_window_seconds":604800},"secondary_window":null}}"#
        let weeklyOnly = try XCTUnwrap(CodexUsageParser.parse(Data(weeklyOnlyPayload.utf8)))

        XCTAssertEqual(weeklyOnly.bars.map(\.label), ["Weekly usage limit"])

        let driftedPayload = #"{"rate_limit":{"primary_window":{"used_percent":20,"reset_at":1894060800,"limit_window_seconds":604800},"secondary_window":{"used_percent":10,"reset_at":1893456000,"limit_window_seconds":17999}}}"#
        let drifted = try XCTUnwrap(CodexUsageParser.parse(Data(driftedPayload.utf8)))

        XCTAssertEqual(drifted.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])

        let outsideTolerancePayload = #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1893456000,"limit_window_seconds":18901}}}"#
        let outsideTolerance = try XCTUnwrap(CodexUsageParser.parse(Data(outsideTolerancePayload.utf8)))

        XCTAssertEqual(outsideTolerance.bars.map(\.label), ["315 minute usage limit"])
    }

    func testCodexUsageParserAcceptsRelativeResetTimes() throws {
        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 15,
              "reset_after_seconds": 3600,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 40,
              "reset_after_seconds": 86400,
              "limit_window_seconds": 604800
            }
          }
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.resetsAt), [
            fetchedAt.addingTimeInterval(3_600),
            fetchedAt.addingTimeInterval(86_400),
        ])
    }

    func testCodexCredentialsParserReadsNamespacedAccountIDFromIDToken() {
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"namespaced-account"}}"#
            .base64URLEncodedForTest()
        let idToken = "\(header).\(payload).signature"

        let credentials = CodexCredentialsParser.parse("""
        {
          "tokens": {
            "access_token": "access-token",
            "id_token": "\(idToken)"
          }
        }
        """)

        XCTAssertEqual(credentials?.accountID, "namespaced-account")
    }

    func testCodexRefreshTokenRequestBodyFormEncodesReservedCharacters() {
        let body = String(
            data: CodexTokenRefresh.makeRefreshTokenRequestBody(refreshToken: "a+b&c=d"),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "grant_type=refresh_token&refresh_token=a%2Bb%26c%3Dd&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
        )
    }

    func testCodexUsageParserAcceptsWindowMinutesWhenLimitSecondsMissing() throws {
        let payload = #"{"rate_limit":{"primary_window":{"used_percent":12,"reset_at":1893456000,"window_minutes":300},"secondary_window":{"used_percent":40,"reset_at":1894060800}}}"#
        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.first?.used, 12)
        XCTAssertEqual(result.bars.last?.used, 40)
    }

    func testCodexAuthFileStorePreservesOwnerOnlyPermissionsAndLastRefresh() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let authFilePath = directory.appendingPathComponent("auth.json").path
        FileManager.default.createFile(atPath: authFilePath, contents: Data("{}".utf8))
        _ = chmod(authFilePath, 0o600)

        try CodexAuthFileStore.writeCredentials(
            CodexCredentials(accessToken: "access-token", refreshToken: "refresh-token"),
            at: authFilePath
        )

        var attributes = stat()
        XCTAssertEqual(stat(authFilePath, &attributes), 0)
        XCTAssertEqual(attributes.st_mode & 0o777, 0o600)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: authFilePath))) as? [String: Any]
        XCTAssertNotNil(root?["last_refresh"] as? String)
    }

    func testCodexUsageProviderExplainsCLIAndBrowserFallback() async throws {
        let configuration = ProviderAccountConfiguration(
            providerID: .codex,
            authMethod: .browserSession
        )
        let provider = CodexUsageProvider(
            secretStore: InMemorySecretStore(),
            authFilePath: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("auth.json").path,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertTrue(result.subtitle.contains("Codex CLI or sign in with ChatGPT"))
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCodexBrowserConfigurationUsesSavedKeychainCredential() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .codex,
            authMethod: .browserSession
        )
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "browser-access",
                expiresAt: 2_000_003_600
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            authFilePath: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent("auth.json").path,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer browser-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":21,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 21)
    }

    func testCodexBrowserConfigurationPrefersHealthyLocalCredential() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authFilePath = directory.appendingPathComponent("auth.json").path
        defer { try? FileManager.default.removeItem(at: directory) }
        try CodexAuthFileStore.writeCredentials(
            CodexCredentials(accessToken: "local-access", expiresAt: 2_000_003_600),
            at: authFilePath
        )

        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .codex,
            authMethod: .browserSession
        )
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "browser-access",
                expiresAt: 2_000_003_600
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            authFilePath: authFilePath,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":22,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 22)
    }

    func testCodexBrowserConfigurationFallsBackWhenLocalCredentialIsExpired() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authFilePath = directory.appendingPathComponent("auth.json").path
        defer { try? FileManager.default.removeItem(at: directory) }
        try CodexAuthFileStore.writeCredentials(
            CodexCredentials(accessToken: "expired-local", expiresAt: 1_999_999_000),
            at: authFilePath
        )

        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .codex,
            authMethod: .browserSession
        )
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "browser-access",
                expiresAt: 2_000_003_600
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            authFilePath: authFilePath,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer browser-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":23,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 23)
    }

    func testCodexBrowserConfigurationFallsBackWhenLocalCredentialIsRejected() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authFilePath = directory.appendingPathComponent("auth.json").path
        defer { try? FileManager.default.removeItem(at: directory) }
        try CodexAuthFileStore.writeCredentials(
            CodexCredentials(accessToken: "revoked-local", expiresAt: 2_000_003_600),
            at: authFilePath
        )

        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .codex,
            authMethod: .browserSession
        )
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "browser-access",
                expiresAt: 2_000_003_600
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            authFilePath: authFilePath,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            let authorization = request.value(forHTTPHeaderField: "Authorization")
            if authorization == "Bearer revoked-local" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            XCTAssertEqual(authorization, "Bearer browser-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":24,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 24)
    }

    func testCodexAuthURLUsesPKCELoopbackFlow() throws {
        let url = CodexWebAuthService.authorizationURL(
            redirectURI: "http://localhost:1455/auth/callback",
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://localhost:1455/auth/callback")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "originator"), "codex_cli_rs")
    }

    func testCodexTokenRequestBodyUsesPKCECodeExchange() {
        let body = String(
            data: CodexWebAuthService.makeTokenRequestBody(
                code: "code value",
                redirectURI: "http://localhost:1455/auth/callback",
                codeVerifier: "verifier value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "grant_type=authorization_code&code=code%20value&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=verifier%20value"
        )
    }

    func testCodexWebAuthReadsNamespacedAccountID() {
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"namespaced-account"}}"#
            .base64URLEncodedForTest()
        let token = "\(header).\(payload).signature"

        XCTAssertEqual(CodexWebAuthService.accountID(from: token), "namespaced-account")
    }

    func testLoopbackOAuthCallbackServerAcceptsRequestsSplitAcrossWrites() async throws {
        let request = Data((
            "GET /callback?code=authorization-code&state=expected-state HTTP/1.1\r\n" +
                "Host: 127.0.0.1\r\nUser-Agent: CodexBarMacTests\r\n\r\n"
        ).utf8)
        let splitOffsets = [1, 37, request.count - 1]

        for (index, splitOffset) in splitOffsets.enumerated() {
            let port = UInt16(36_187 + index)
            let server = try await makeLoopbackCallbackServer(preferredPorts: [port])
            defer { server.cancel() }
            let callbackTask = Task {
                try await server.waitForCallback(timeoutNanoseconds: 2_000_000_000)
            }

            let response = try await sendRawHTTPRequest(
                port: port,
                chunks: [Data(request[..<splitOffset]), Data(request[splitOffset...])]
            )
            let callbackURL = try await callbackTask.value

            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"))
            XCTAssertEqual(callbackURL.path, "/callback")
            XCTAssertEqual(
                URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                    .queryItemValue(named: "code"),
                "authorization-code"
            )
        }
    }

    func testLoopbackOAuthCallbackServerRejectsOversizedRequest() async throws {
        let port: UInt16 = 36_190
        let server = try await makeLoopbackCallbackServer(
            preferredPorts: [port],
            maximumRequestLength: 64
        )
        defer { server.cancel() }
        let callbackTask = Task {
            try await server.waitForCallback(timeoutNanoseconds: 2_000_000_000)
        }

        let response = try await sendRawHTTPRequest(
            port: port,
            chunks: [Data(("GET /callback?" + String(repeating: "x", count: 128)).utf8)]
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 413 Payload Too Large"))
        do {
            _ = try await callbackTask.value
            XCTFail("Expected an oversized callback request to fail.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .missingAuthorizationCode)
        }
    }

    func testLoopbackOAuthCallbackServerRejectsPrematurelyClosedRequest() async throws {
        let port: UInt16 = 36_191
        let server = try await makeLoopbackCallbackServer(preferredPorts: [port])
        defer { server.cancel() }
        let callbackTask = Task {
            try await server.waitForCallback(timeoutNanoseconds: 2_000_000_000)
        }

        let response = try await sendRawHTTPRequest(
            port: port,
            chunks: [Data("GET /callback?code=authorization-code".utf8)],
            finishWriting: true
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request"))
        do {
            _ = try await callbackTask.value
            XCTFail("Expected a prematurely closed callback request to fail.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .missingAuthorizationCode)
        }
    }

    @MainActor
    func testCodexBrowserSignInUsesLocalhostRedirectAndTimesOut() async throws {
        let service = CodexWebAuthService(callbackTimeoutNanoseconds: 10_000_000)
        var presentedURL: URL?

        do {
            _ = try await service.signIn {
                presentedURL = $0
                return true
            }
            XCTFail("Expected ChatGPT browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? CodexWebAuthService.AuthError, .callbackTimedOut)
        }

        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(components.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "localhost")
    }

    func testCodexUsageProviderFallsBackToSavedKeychainCredentialWithoutAuthFile() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "keychain-access",
                expiresAt: 2_000_003_600
            )),
            account: account
        )

        let authDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authFilePath = authDirectory.appendingPathComponent("auth.json").path
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            authFilePath: authFilePath,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer keychain-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":18,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 18)
    }

    func testCodexUsageProviderReusesExternallyRefreshedCredentialsAfterRejectedRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: authDirectory) }

        let authFilePath = authDirectory.appendingPathComponent("auth.json").path
        try CodexAuthFileStore.writeCredentials(
            CodexCredentials(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expiresAt: 2_000_000_060
            ),
            at: authFilePath
        )

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            authFilePath: authFilePath,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            if request.url?.path == "/codex-token" {
                try CodexAuthFileStore.writeCredentials(
                    CodexCredentials(
                        accessToken: "shared-access",
                        refreshToken: "shared-refresh",
                        expiresAt: 2_000_003_600
                    ),
                    at: authFilePath
                )
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":"invalid_grant"}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer shared-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":33,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 33)
    }

    func testCodexUsageProviderProactivelyRefreshesAndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: authDirectory) }

        let authFilePath = authDirectory.appendingPathComponent("auth.json").path
        try CodexAuthFileStore.writeCredentials(
            CodexCredentials(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                idToken: "old-id",
                accountID: "account-id",
                expiresAt: 2_000_000_060
            ),
            at: authFilePath
        )

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CodexUsageProvider(
            session: session,
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            authFilePath: authFilePath,
            now: { now }
        )
        var requestCount = 0

        MockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/codex-token" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.timeoutInterval, 15)
                XCTAssertEqual(
                    String(data: try XCTUnwrap(requestBodyData(from: request)), encoding: .utf8),
                    "grant_type=refresh_token&refresh_token=old-refresh&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
                )
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-id")
            let persisted = try XCTUnwrap(CodexAuthFileStore.readCredentials(at: authFilePath))
            XCTAssertEqual(persisted.accessToken, "new-access")
            XCTAssertEqual(persisted.refreshToken, "new-refresh")
            XCTAssertEqual(persisted.expiresAt, 2_000_003_600)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCodexUsageProviderSilentlyPreservesWeeklyOnlyUsage() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: authDirectory) }

        let authFilePath = authDirectory.appendingPathComponent("auth.json").path
        try CodexAuthFileStore.writeCredentials(
            CodexCredentials(
                accessToken: "codex-access",
                expiresAt: 2_000_003_600
            ),
            at: authFilePath
        )

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            authFilePath: authFilePath,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/codex-usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":30,"reset_at":2000604800,"limit_window_seconds":604800},"secondary_window":null}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.bars.map(\.label), ["Weekly usage limit"])
    }

    func testCodexUsageProviderSendsNamespacedAccountIDHeader() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let authDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: authDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: authDirectory) }

        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"namespaced-account"}}"#
            .base64URLEncodedForTest()
        let idToken = "\(header).\(payload).signature"
        let authFilePath = authDirectory.appendingPathComponent("auth.json").path
        try CodexAuthFileStore.writeCredentials(
            CodexCredentials(
                accessToken: "codex-access",
                idToken: idToken,
                expiresAt: 2_000_003_600
            ),
            at: authFilePath
        )

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            authFilePath: authFilePath,
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "namespaced-account")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":10,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        _ = try await provider.fetchUsage(for: configuration)
    }

    func testClaudeUsageParserReadsOAuthUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "de_DE")
        )
        let payload = """
        {
          "five_hour": {
            "utilization": 42,
            "resets_at": "2030-01-01T00:00:00Z"
          },
          "seven_day": {
            "utilization": 81,
            "resets_at": "2030-01-08T00:00:00Z"
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro",
            fetchedAt: fetchedAt,
            dateTimeFormatter: formatter
        ))

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.title, "Claude (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
    }

    func testClaudeUsageParserSurfacesOAuthAppsWeeklyLimitSeparately() throws {
        let payload = """
        {
          "five_hour": {
            "utilization": 12,
            "resets_at": "2030-01-01T00:00:00Z"
          },
          "seven_day": {
            "utilization": 34,
            "resets_at": "2030-01-08T00:00:00Z"
          },
          "seven_day_oauth_apps": {
            "utilization": 61,
            "resets_at": "2030-01-08T12:00:00Z"
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "Weekly usage limit",
            "OAuth apps weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [12, 34, 61])
    }

    func testClaudeUsageParserLabelsOAuthAppsWeeklyLimitWhenAllModelWeeklyIsAbsent() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"seven_day_oauth_apps":{"utilization":55,"resets_at":"2030-01-08T00:00:00Z"}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["OAuth apps weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [55])
    }

    func testClaudeUsageParserPreservesSubOnePercentOAuthUtilization() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":0.5,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.first?.used, 0.5)
    }

    func testClaudeUsageParserReadsStructuredAndScopedLimitsWithoutDuplicates() throws {
        let payload = """
        {
          "five_hour": {"utilization": 0.99, "resets_at": "2030-01-01T00:00:00Z"},
          "seven_day": {"utilization": 0.88, "resets_at": "2030-01-08T00:00:00Z"},
          "limits": [
            {"kind":"session","percent":15,"is_active":true},
            {"kind":"weekly_all","percent":36,"resets_at":"2030-01-08T00:00:00Z","is_active":true},
            {"kind":"weekly_scoped","percent":71,"resets_at":"2030-01-08T00:00:00.838164+00:00","scope":{"model":{"display_name":"Fable"}},"is_active":true},
            {"kind":"weekly_scoped","percent":49,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":true}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max_20x"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "All models weekly usage limit",
            "Fable weekly usage limit",
            "Claude Sonnet 4.5 weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [15, 36, 71, 49])
        XCTAssertEqual(result.bars.last?.stableKey, "weekly-scoped-claudesonnet45")
    }

    func testClaudeUsageParserShowsObservedInactiveFableWeeklyLimit() throws {
        let payload = """
        {
          "limits": [
            {"kind":"session","percent":11,"resets_at":"2030-01-01T02:00:00Z","is_active":true},
            {"kind":"weekly_all","percent":9,"resets_at":"2030-01-08T04:00:00Z","is_active":false},
            {"kind":"weekly_scoped","percent":5,"resets_at":"2030-01-08T04:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":false}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "All models weekly usage limit",
            "Fable weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [11, 9, 5])
    }

    func testClaudeUsageParserReadsScopedWeeklyRateLimitHeaders() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "0.42",
                "anthropic-ratelimit-unified-5h-reset": "1893456000",
                "anthropic-ratelimit-unified-7d-utilization": "0.65",
                "anthropic-ratelimit-unified-7d-reset": "1894060800",
                "anthropic-ratelimit-unified-7d_sonnet-utilization": "0.88",
                "anthropic-ratelimit-unified-7d_sonnet-reset": "1894060800",
                "anthropic-ratelimit-unified-7d-opus-utilization": "0.31",
                "anthropic-ratelimit-unified-7d-opus-reset": "1894060800",
            ],
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "Weekly usage limit",
            "Sonnet weekly usage limit",
            "Opus weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [42, 65, 88, 31])
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "session",
            "weekly-all",
            "weekly-scoped-sonnet",
            "weekly-scoped-opus",
        ])
    }

    func testClaudeUsageParserMatchesRateLimitHeadersCaseInsensitively() throws {
        let result = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "Anthropic-Ratelimit-Unified-5H-Utilization": "0.42",
                "ANTHROPIC-RATELIMIT-UNIFIED-5H-RESET": "1893456000",
            ],
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit"])
        XCTAssertEqual(result.bars.first?.used, 42)
    }

    func testClaudeUsageParserReadsCurrencyAwareUsageCredits() throws {
        let payload = """
        {
          "limits": [{"kind":"weekly_all","percent":24,"is_active":true}],
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 5000,
            "used_credits": 1250,
            "currency": "EUR",
            "decimal_places": 2
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.first?.used, 24)
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [Decimal(1250), Decimal(5000), Decimal(3750)])
        XCTAssertEqual(result.monetaryMetrics.map(\.amount), [Decimal(string: "12.5")!, Decimal(50), Decimal(string: "37.5")!])
        XCTAssertEqual(result.monetaryMetrics.map(\.currencyCode), ["EUR", "EUR", "EUR"])
        XCTAssertEqual(result.monetaryMetrics.last?.detail, "Not a prepaid balance")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertFalse(result.hasReachedSpendLimit)
    }

    func testClaudeUsageParserRepresentsDisabledUnlimitedAndMalformedExtraUsage() throws {
        let disabled = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":false,"disabled_reason":"Not funded"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(disabled.usageMessages, ["Usage credits are disabled: Not funded."])
        XCTAssertTrue(disabled.monetaryMetrics.isEmpty)

        let unlimited = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":250,"currency":"GBP","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(unlimited.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(unlimited.usageMessages, ["Usage credits are enabled with no monthly spend limit reported."])

        let malformed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"unknown","percent":50}],"extra_usage":{"is_enabled":true,"used_credits":10,"currency":"US"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(malformed.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            malformed.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let missingCurrency = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(missingCurrency.monetaryMetrics.map(\.currencyCode), ["USD", "USD", "USD"])
        XCTAssertEqual(missingCurrency.monetaryMetrics.map(\.amount), [12.5, 50, 37.5])

        let reachedLimit = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":5000,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(reachedLimit.hasReachedSpendLimit)
        XCTAssertEqual(
            reachedLimit.usageMessages,
            ["The monthly usage-credit spend limit has been reached."]
        )

        let lossyExtraUsage = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"weekly_all","percent":24,"is_active":true}],"extra_usage":{"is_enabled":true,"used_credits":"not-a-number","monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(lossyExtraUsage.bars.first?.used, 24)
        XCTAssertTrue(lossyExtraUsage.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            lossyExtraUsage.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let lossyOptionalFields = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"weekly_all","percent":18,"is_active":true}],"extra_usage":{"is_enabled":"yes","used_credits":1250,"monthly_limit":5000,"currency":123,"disabled_reason":false,"decimal_places":2}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(lossyOptionalFields.bars.first?.used, 18)
        XCTAssertEqual(lossyOptionalFields.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(lossyOptionalFields.monetaryMetrics.map(\.currencyCode), ["USD", "USD", "USD"])
        XCTAssertEqual(
            lossyOptionalFields.usageMessages,
            ["Usage-credit enabled status was not reported."]
        )
    }

    func testClaudeUsageParserPrefersSpendPayloadOverExtraUsage() throws {
        let withLimit = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"weekly_all","percent":40,"is_active":true}],"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2},"balance":null},"extra_usage":{"is_enabled":true,"used_credits":99,"monthly_limit":100,"currency":"EUR","decimal_places":2}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(withLimit.bars.first?.used, 40)
        XCTAssertEqual(withLimit.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(withLimit.monetaryMetrics.map(\.minorUnits), [Decimal(1250), Decimal(5000), Decimal(3750)])
        XCTAssertEqual(withLimit.monetaryMetrics.map(\.currencyCode), ["USD", "USD", "USD"])
        XCTAssertFalse(withLimit.hasReachedSpendLimit)

        let balanceOnly = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"balance":{"amount_minor":500,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(balanceOnly.monetaryMetrics.map(\.kind), [.balance])
        XCTAssertEqual(balanceOnly.monetaryMetrics.first?.amount, Decimal(5))
        XCTAssertEqual(balanceOnly.monetaryMetrics.first?.detail, "Prepaid balance")

        let negativeBalance = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"balance":{"amount_minor":-250,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(negativeBalance.monetaryMetrics.map(\.kind), [.balance])
        XCTAssertEqual(negativeBalance.monetaryMetrics.first?.minorUnits, Decimal(-250))
        XCTAssertEqual(negativeBalance.monetaryMetrics.first?.amount, Decimal(string: "-2.5")!)

        let limitAndBalance = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2},"balance":{"amount_minor":800,"currency":"USD","exponent":2}}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            limitAndBalance.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .remainingHeadroom, .balance]
        )
        XCTAssertEqual(limitAndBalance.monetaryMetrics.map(\.minorUnits), [
            Decimal(1250), Decimal(5000), Decimal(3750), Decimal(800),
        ])

        let disabledSpend = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":false,"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"balance":null}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(disabledSpend.monetaryMetrics.isEmpty)
        XCTAssertEqual(disabledSpend.usageMessages, ["Usage credits are disabled."])

        let lossySpend = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"session","percent":12,"is_active":true}],"spend":{"enabled":true,"used":"broken"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(lossySpend.bars.first?.used, 12)
        XCTAssertTrue(lossySpend.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            lossySpend.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let unusableSpendFallsBackToExtraUsage = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"spend":{"enabled":true,"used":"broken"},"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            unusableSpendFallsBackToExtraUsage.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .remainingHeadroom]
        )
        XCTAssertEqual(
            unusableSpendFallsBackToExtraUsage.monetaryMetrics.map(\.minorUnits),
            [Decimal(1250), Decimal(5000), Decimal(3750)]
        )
    }

    func testClaudeCredentialStorePreservesFilePermissionsAndMetadata() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        let original = """
        {
          "otherEntry": {"enabled": true},
          "claudeAiOauth": {
            "accessToken": "old-access",
            "refreshToken": "refresh-token",
            "expiresAt": 1000,
            "scopes": ["user:inference", "user:profile"]
          }
        }
        """
        try Data(original.utf8).write(to: URL(fileURLWithPath: credentialsPath))
        _ = chmod(credentialsPath, 0o600)

        try ClaudeCredentialStore.saveCredentials(
            ClaudeCredentials(
                expiresAt: 4_000_000_000_000,
                accessToken: "new-access",
                refreshToken: "refresh-token"
            ),
            to: .file(credentialsPath)
        )

        var attributes = stat()
        XCTAssertEqual(stat(credentialsPath, &attributes), 0)
        XCTAssertEqual(attributes.st_mode & 0o777, 0o600)

        let root = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: credentialsPath))
        ) as? [String: Any]
        let otherEntry = root?["otherEntry"] as? [String: Any]
        XCTAssertEqual(otherEntry?["enabled"] as? Bool, true)
        let oauth = root?["claudeAiOauth"] as? [String: Any]
        XCTAssertEqual(oauth?["accessToken"] as? String, "new-access")
        XCTAssertEqual(oauth?["refreshToken"] as? String, "refresh-token")
        XCTAssertEqual(oauth?["scopes"] as? [String], ["user:inference", "user:profile"])
    }

    func testClaudeAuthURLUsesPKCELoopbackFlow() throws {
        let url = ClaudeWebAuthService.authorizationURL(
            redirectURI: "http://localhost:1461/callback",
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(components.path, "/cai/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://localhost:1461/callback")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "state"), "state")
    }

    func testClaudeTokenRequestBodyUsesAuthorizationCodeExchange() throws {
        let data = ClaudeWebAuthService.makeTokenRequestBody(
            code: "code value",
            redirectURI: "http://localhost:1461/callback",
            state: "state value",
            codeVerifier: "verifier value"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["code"], "code value")
        XCTAssertEqual(body["redirect_uri"], "http://localhost:1461/callback")
        XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(body["code_verifier"], "verifier value")
        XCTAssertEqual(body["state"], "state value")
    }

    @MainActor
    func testClaudeBrowserSignInUsesLocalhostRedirectAndTimesOut() async throws {
        let service = ClaudeWebAuthService(callbackTimeoutNanoseconds: 10_000_000)
        var presentedURL: URL?

        do {
            _ = try await service.signIn {
                presentedURL = $0
                return true
            }
            XCTFail("Expected Claude browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .callbackTimedOut)
        }

        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(components.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "localhost")
    }

    func testTokenEndpointErrorFormatterRedactsUntrustedDetails() {
        let body = Data(#"{"error":"invalid_grant","error_description":"authorization code=secret-code client_id=secret-client"}"#.utf8)

        let message = TokenEndpointErrorFormatter.message(statusCode: 400, body: body)

        XCTAssertEqual(message, "HTTP 400 (invalid_grant)")
        XCTAssertFalse(message.contains("secret-code"))
        XCTAssertFalse(message.contains("secret-client"))
        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(
                statusCode: 502,
                body: Data("authorization: Bearer secret-token".utf8)
            ),
            "HTTP 502"
        )
    }

    func testClaudeCredentialStoreRejectsWhitespaceOnlyAccessTokens() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data("""
        {
          "claudeAiOauth": {
            "accessToken": "   ",
            "refreshToken": "refresh-token",
            "expiresAt": 4000000000000
          }
        }
        """.utf8).write(to: URL(fileURLWithPath: credentialsPath))

        XCTAssertNil(ClaudeCredentialStore.readCredentials(
            keychainAccount: "codexbar-tests-\(UUID().uuidString)",
            credentialsFilePath: credentialsPath
        ))
        XCTAssertNil(ClaudeCredentialStore.readCredentials(from: .file(credentialsPath)))
    }

    func testClaudeUsageProviderReadsLocalCredentialsFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer claude-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":50,"resets_at":"2030-01-08T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(result.bars.map(\.used), [25, 50])
    }

    func testClaudeUsageProviderUsesBrowserCredentialWhenLocalCredentialsAreAbsent() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .claude,
            authMethod: .browserSession
        )
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                expiresAt: 4_000_000_000_000,
                accessToken: "browser-claude-access",
                refreshToken: "redacted-refresh"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathComponent(".credentials.json").path,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer browser-claude-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":31,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 31)
    }

    func testClaudeBrowserConfigurationPrefersHealthyLocalCredential() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 2_000_003_600,
            accessToken: "healthy-local"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .claude, authMethod: .browserSession)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                expiresAt: 2_000_003_600,
                accessToken: "browser-access"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)",
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer healthy-local")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":21,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 21)
    }

    func testClaudeBrowserConfigurationFallsBackWhenLocalCredentialIsExpired() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 1_999_999_900,
            accessToken: "expired-local"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .claude, authMethod: .browserSession)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                expiresAt: 2_000_003_600,
                accessToken: "browser-access"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)",
            now: { now }
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer browser-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":32,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 32)
    }

    func testClaudeBrowserConfigurationFallsBackWhenLocalCredentialIsRejected() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 2_000_003_600,
            accessToken: "revoked-local"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration(providerID: .claude, authMethod: .browserSession)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                expiresAt: 2_000_003_600,
                accessToken: "browser-access"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)",
            now: { now }
        )
        MockURLProtocol.handler = { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer revoked-local" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer browser-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":43,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 43)
    }

    func testClaudeUsageProviderReturnsMonetaryOnlyWithoutMessagesProbe() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(try XCTUnwrap(result.monetaryMetrics.first?.amount), Decimal(string: "12.5")!)
        XCTAssertTrue(result.isIncompleteRefresh)
    }

    func testClaudeUsageProviderDoesNotProbeMessagesWhenOAuthPayloadIsUnrecognized() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.subtitle, "Claude usage did not include rate-limit windows.")
        XCTAssertTrue(result.isIncompleteRefresh)
    }

    func testClaudeUsageProviderPreservesCachedBarsWhenOAuthReturnsMonetaryOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )

        var oauthCalls = 0
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            oauthCalls += 1
            if oauthCalls == 1 {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"limits":[{"kind":"weekly_all","percent":33,"is_active":true}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"spend":{"enabled":true,"used":{"amount_minor":1250,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let seeded = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))
        XCTAssertEqual(seeded.bars.map(\.used), [33])

        let refreshed = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))
        XCTAssertEqual(oauthCalls, 2)
        XCTAssertEqual(refreshed.bars.map(\.used), [33])
        XCTAssertEqual(refreshed.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(try XCTUnwrap(refreshed.monetaryMetrics.first?.amount), Decimal(string: "12.5")!)
        XCTAssertTrue(refreshed.isIncompleteRefresh)
    }

    func testClaudeUsageProviderDoesNotProbeMessagesWhenOAuthUsageIsForbidden() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.subtitle, "Claude credential lacks permission to read subscription usage.")
        XCTAssertTrue(result.isIncompleteRefresh)
    }

    func testClaudeUsageProviderPreservesCachedBarsWhenOAuthUsageIsForbidden() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "claude-access"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            if requestCount == 1 {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"limits":[{"kind":"weekly_all","percent":37,"is_active":true}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let fresh = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))
        let forbidden = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(forbidden.bars, fresh.bars)
        XCTAssertTrue(forbidden.subtitle.contains("lacks permission"))
        XCTAssertTrue(forbidden.subtitle.contains("Showing last known data."))
        XCTAssertTrue(forbidden.isIncompleteRefresh)
    }

    func testClaudeUsageProviderPreservesSnapshotAfter401TriggeredRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let credentialsPath = directory.appendingPathComponent(".credentials.json").path
        try Data(ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            expiresAt: 4_000_000_000_000,
            accessToken: "old-access",
            refreshToken: "refresh-token"
        )).utf8).write(to: URL(fileURLWithPath: credentialsPath))

        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            credentialsFilePath: credentialsPath,
            keychainAccount: "codexbar-tests-\(UUID().uuidString)"
        )
        var usageRequestCount = 0

        MockURLProtocol.handler = { request in
            if request.url?.path == "/v1/oauth/token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"refresh-token","expires_in":3600}"#.utf8)
                )
            }

            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            usageRequestCount += 1
            if usageRequestCount == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            if usageRequestCount == 2 {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"five_hour":{"utilization":25,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":50,"resets_at":"2030-01-08T00:00:00Z"}}"#.utf8)
                )
            }

            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "60"]
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.handler = nil }

        let firstResult = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(firstResult.bars.map(\.used), [25, 50])

        let secondResult = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(secondResult.bars.map(\.used), [25, 50])
        XCTAssertTrue(secondResult.subtitle.contains("Showing last known data."))
    }

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
            XCTAssertEqual(request.url?.path, "/workspace/wrk_test/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                Data(#"<html>data balance:2575000000 more</html>"#.utf8)
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
            XCTAssertEqual(request.url?.path, "/workspace/wrk_from_windows/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=go-dashboard-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"<html>balance:625000000</html>"#.utf8)
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
                Data(#"<html>balance:100000000</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 1.0, accuracy: 0.0001)
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterStoresWindowsSettingsJSON() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let secretStore = InMemorySecretStore()
        let configurationStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """

        XCTAssertTrue(OpenCodeZenBootstrapImporter.importPayload(payload, configurationStore: configurationStore))

        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_from_windows")
        XCTAssertEqual(configuration.accountLabel, "OpenCode ZEN")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            "go-dashboard-token"
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterRetainsFileForInvalidPayload() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let importURL = tempDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data().write(to: importURL)

        let configurationStore = ProviderConfigurationStore(
            defaults: UserDefaults(suiteName: "OpenCodeZenBootstrapImporter-invalid-\(UUID().uuidString)")!,
            secretStore: InMemorySecretStore()
        )

        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            importDirectory: tempDirectory
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: importURL.path))
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterDeletesFileAfterSuccessfulImport() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let importURL = tempDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: importURL)

        let configurationStore = ProviderConfigurationStore(
            defaults: UserDefaults(suiteName: "OpenCodeZenBootstrapImporter-success-\(UUID().uuidString)")!,
            secretStore: InMemorySecretStore()
        )

        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            importDirectory: tempDirectory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: importURL.path))
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterReturnsFalseWhenSecretSaveFails() throws {
        let secretStore = FailingSecretStore()
        let configurationStore = ProviderConfigurationStore(
            defaults: UserDefaults(suiteName: "OpenCodeZenBootstrapImporter-failure-\(UUID().uuidString)")!,
            secretStore: secretStore
        )
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """

        XCTAssertFalse(OpenCodeZenBootstrapImporter.importPayload(payload, configurationStore: configurationStore))
        XCTAssertNil(configurationStore.readSavedSecret(for: .defaultConfiguration(for: .openCodeZen)))
    }

    func testOpenCodeZenNormalizesPastedBalanceCredential() {
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Authorization: Bearer oczen-test-key"),
            "oczen-test-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "\"quoted-key\""),
            "quoted-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "auth=oczen-legacy-shaped-key; other=value"),
            "oczen-legacy-shaped-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedWorkspaceId(from: "https://opencode.ai/workspace/wrk_test/billing"),
            "wrk_test"
        )
    }

    func testOpenCodeZenProviderWithoutWorkspaceIsNotConfigured() async throws {
        let secretStore = InMemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        try secretStore.saveSecret("oczen-test-key", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let provider = OpenCodeZenUsageProvider(secretStore: secretStore)
        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "Not configured - enter OpenCode workspace ID.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = OpenCodeZenUsageProvider(secretStore: InMemorySecretStore())
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "Not configured - enter OpenCode dashboard auth value.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    @MainActor
    func testApplyLocalCredentialDiscoveriesCreatesMissingGeminiAccount() throws {
        let suiteName = "CodexBarMacTests.GeminiDiscovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preexisting = ProviderID.allCases
            .filter { $0 != .gemini }
            .map(ProviderAccountConfiguration.defaultConfiguration)
        defaults.set(try JSONEncoder().encode(preexisting), forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertTrue(store.configurations(for: .gemini).isEmpty)

        store.applyLocalCredentialDiscoveries(
            LocalCredentialDiscovery.Result(
                codexAuthAvailable: false,
                githubUsernames: [],
                claudeOAuthAvailable: false,
                geminiOAuthAvailable: true
            )
        )

        let gemini = try XCTUnwrap(store.configurations(for: .gemini).first)
        XCTAssertEqual(gemini.authMethod, .oauth)
        XCTAssertEqual(store.localCredentialHints[gemini.id], "~/.gemini/oauth_creds.json")
    }

    @MainActor
    func testApplyLocalCredentialDiscoveriesRespectsDeletedGeminiAccount() throws {
        let suiteName = "CodexBarMacTests.GeminiDiscoverySuppressed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let preexisting = ProviderID.allCases.map(ProviderAccountConfiguration.defaultConfiguration)
        defaults.set(try JSONEncoder().encode(preexisting), forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        let gemini = try XCTUnwrap(store.configurations(for: .gemini).first)
        store.removeAccount(gemini)
        XCTAssertTrue(store.configurations(for: .gemini).isEmpty)

        store.applyLocalCredentialDiscoveries(
            LocalCredentialDiscovery.Result(
                codexAuthAvailable: false,
                githubUsernames: [],
                claudeOAuthAvailable: false,
                geminiOAuthAvailable: true
            )
        )

        XCTAssertTrue(store.configurations(for: .gemini).isEmpty)
    }

    func testProviderAccountConfigurationDefaultsLegacyHistoryVisibilityOn() throws {
        let json = """
        {
          "id": "codex.personal",
          "providerID": "codex",
          "isEnabled": true,
          "accountLabel": "Personal",
          "authMethod": "codexAuthJSON"
        }
        """

        let configuration = try JSONDecoder().decode(
            ProviderAccountConfiguration.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(configuration.showsHistory)
    }

    @MainActor
    func testProviderHistoryVisibilityPersistsIndependentlyAcrossAccounts() throws {
        let suiteName = "CodexBarMacTests.HistoryVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        var codex = store.addAccount(for: .codex)
        let claude = store.addAccount(for: .claude)

        XCTAssertTrue(codex.showsHistory)
        XCTAssertTrue(claude.showsHistory)

        codex.showsHistory = false
        XCTAssertTrue(store.update(codex))

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertFalse(try XCTUnwrap(reloadedStore.configuration(accountID: codex.id)?.showsHistory))
        XCTAssertTrue(try XCTUnwrap(reloadedStore.configuration(accountID: claude.id)?.showsHistory))
    }

    @MainActor
    func testProviderAccountGroupsPersistAndValidateNames() throws {
        let suiteName = "CodexBarMacTests.Groups.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        let work = try XCTUnwrap(store.addGroup(named: "  Work  "))
        let personal = try XCTUnwrap(store.addGroup(named: "Personal"))

        XCTAssertEqual(store.groups.map(\.name), ["Personal", "Work"])
        XCTAssertNil(store.addGroup(named: "work"))
        XCTAssertEqual(store.lastError, "Group names must be unique.")

        var renamed = personal
        renamed.name = "  Home  "
        XCTAssertTrue(store.updateGroup(renamed))

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertEqual(reloadedStore.groups.map(\.name), ["Home", "Work"])
        XCTAssertEqual(reloadedStore.group(for: work.id)?.name, "Work")
    }

    @MainActor
    func testRemovingProviderAccountGroupUngroupsAssignedAccounts() throws {
        let suiteName = "CodexBarMacTests.GroupRemoval.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        let group = try XCTUnwrap(store.addGroup(named: "Work"))
        var account = store.addAccount(for: .codex)
        account.groupID = group.id
        XCTAssertTrue(store.update(account))
        XCTAssertEqual(store.configuration(accountID: account.id)?.groupID, group.id)

        store.removeGroup(group)

        XCTAssertTrue(store.groups.isEmpty)
        XCTAssertNil(store.configuration(accountID: account.id)?.groupID)
        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: InMemorySecretStore())
        XCTAssertTrue(reloadedStore.groups.isEmpty)
        XCTAssertNil(reloadedStore.configuration(accountID: account.id)?.groupID)
    }

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
        XCTAssertEqual(evaluation.activeAlerts.first?.message, "Total is currently at 76%.")
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
        XCTAssertEqual(evaluation.activeAlerts.first?.message, "Weekly is projected to reach 100%.")
    }

    func testUsageAlertEvaluatorExplainsReachedSpendLimit() {
        let result = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Included usage",
            bars: [],
            hasReachedSpendLimit: true,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(isEnabled: true, includesSeverityAlerts: true),
            activeAlertIDs: []
        )

        XCTAssertEqual(evaluation.notifications.map(\.kind), [.severity])
        XCTAssertEqual(evaluation.activeAlerts.first?.title, "Critical status")
        XCTAssertEqual(
            evaluation.activeAlerts.first?.message,
            "The monthly usage-credit spend limit has been reached."
        )
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

    func testLocalCredentialDiscoveryParsesGitHubAuthStatusUsernames() {
        let output = """
        github.com
          ✓ Logged in to github.com account octocat (keyring)
          ✓ Logged in to github.com account hubot (keyring)
          ✓ Logged in to github.com account octocat (keyring)
        """

        XCTAssertEqual(
            LocalCredentialDiscovery.extractGitHubUsernames(from: output),
            ["octocat", "hubot"]
        )
        XCTAssertEqual(
            LocalCredentialDiscovery.extractUsername(from: "✓ Logged in to github.com as mona"),
            "mona"
        )
        XCTAssertTrue(
            LocalCredentialDiscovery.extractGitHubUsernames(
                from: "Logged in to gitlab.com account ignored"
            ).isEmpty
        )
    }

    func testGeminiCredentialsParserReadsOAuthFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = directory.appendingPathComponent("oauth_creds.json").path
        let json = """
        {
          "access_token": "redacted-access-token",
          "refresh_token": "redacted-refresh-token",
          "expiry_date": 4102444800000,
          "client_id": "redacted-client-id",
          "client_secret": "redacted-client-secret"
        }
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        _ = chmod(path, 0o600)

        let credentials = try XCTUnwrap(GeminiCredentialsParser.parseCredentialsFile(at: path))
        XCTAssertEqual(credentials.accessToken, "redacted-access-token")
        XCTAssertEqual(credentials.refreshToken, "redacted-refresh-token")
        XCTAssertEqual(credentials.expiryDateMs, 4_102_444_800_000)
        XCTAssertEqual(credentials.clientID, "redacted-client-id")
        XCTAssertEqual(credentials.clientSecret, "redacted-client-secret")
        XCTAssertFalse(credentials.shouldRefresh(at: Date(timeIntervalSince1970: 2_000_000_000)))
    }

    func testGeminiTokenRefreshBuildsRequestBodyFromResolvedCredentials() throws {
        let credentials = GeminiCredentials(
            refreshToken: "refresh+token/with=special&chars",
            clientID: "client id+value",
            clientSecret: "secret/with+special=&chars"
        )

        let clientID = try XCTUnwrap(GeminiTokenRefresh.resolveClientID(from: credentials))
        let clientSecret = try XCTUnwrap(GeminiTokenRefresh.resolveClientSecret(from: credentials))
        let body = GeminiTokenRefresh.makeRefreshTokenRequestBody(
            refreshToken: "refresh+token/with=special&chars",
            clientID: clientID,
            clientSecret: clientSecret
        )
        let encoded = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertTrue(encoded.contains("grant_type=refresh_token"))
        XCTAssertTrue(encoded.contains("refresh_token=refresh%2Btoken%2Fwith%3Dspecial%26chars"))
        XCTAssertTrue(encoded.contains("client_id=client%20id%2Bvalue"))
        XCTAssertTrue(encoded.contains("client_secret=secret%2Fwith%2Bspecial%3D%26chars"))
    }

    func testGeminiTokenRefreshFallsBackToInstalledClientCredentials() {
        let credentials = GeminiCredentials(refreshToken: "redacted-refresh-token")

        XCTAssertTrue(GeminiTokenRefresh.resolveClientID(from: credentials)?.hasSuffix(".apps.googleusercontent.com") == true)
        XCTAssertTrue(GeminiTokenRefresh.resolveClientSecret(from: credentials)?.hasPrefix("GOCSPX-") == true)
    }

    func testGeminiUsageParserReadsProAndFlashBuckets() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resetTime = ISO8601DateFormatter().string(
            from: fetchedAt.addingTimeInterval(7_500)
        )
        let json = """
        {
          "buckets": [
            {
              "tokenType": "REQUESTS",
              "modelId": "gemini-2.5-pro",
              "remainingFraction": 0.72,
              "resetTime": "\(resetTime)"
            },
            {
              "tokenType": "REQUESTS",
              "modelId": "gemini-2.5-flash",
              "remainingFraction": 0.45,
              "resetTime": "\(resetTime)"
            }
          ]
        }
        """

        let result = try XCTUnwrap(
            GeminiUsageParser.parseQuota(Data(json.utf8), tierName: "Code Assist", fetchedAt: fetchedAt)
        )

        XCTAssertEqual(result.bars.count, 2)
        XCTAssertEqual(result.bars[0].label, "Pro (Code Assist)")
        XCTAssertEqual(result.bars[0].used, 0.28, accuracy: 0.0001)
        XCTAssertEqual(result.bars[1].label, "Flash")
        XCTAssertEqual(result.bars[1].used, 0.55, accuracy: 0.0001)
        XCTAssertEqual(result.bars[0].resetDescription, "Resets in 2h 5m")
    }

    func testGeminiUsageParserExcludesFlashLiteFromFlashAggregate() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resetTime = ISO8601DateFormatter().string(
            from: fetchedAt.addingTimeInterval(3_600)
        )
        let json = """
        {
          "buckets": [
            {
              "tokenType": "REQUESTS",
              "modelId": "gemini-2.5-flash",
              "remainingFraction": 0.8,
              "resetTime": "\(resetTime)"
            },
            {
              "tokenType": "REQUESTS",
              "modelId": "gemini-2.5-flash-lite",
              "remainingFraction": 0.05,
              "resetTime": "\(resetTime)"
            }
          ]
        }
        """

        let result = try XCTUnwrap(
            GeminiUsageParser.parseQuota(Data(json.utf8), tierName: nil, fetchedAt: fetchedAt)
        )

        XCTAssertEqual(result.bars.count, 1)
        XCTAssertEqual(result.bars[0].label, "Flash")
        XCTAssertEqual(result.bars[0].used, 0.2, accuracy: 0.0001)
    }

    func testGeminiUsageParserUsesLowestRemainingAcrossTokenBucketTypes() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let resetTime = ISO8601DateFormatter().string(
            from: fetchedAt.addingTimeInterval(3_600)
        )
        let json = """
        {
          "buckets": [
            {
              "tokenType": "REQUESTS",
              "modelId": "gemini-2.5-pro",
              "remainingFraction": 0.8,
              "resetTime": "\(resetTime)"
            },
            {
              "tokenType": "INPUT_TOKENS",
              "modelId": "gemini-2.5-pro",
              "remainingFraction": 0.1,
              "resetTime": "\(resetTime)"
            }
          ]
        }
        """

        let result = try XCTUnwrap(
            GeminiUsageParser.parseQuota(Data(json.utf8), tierName: nil, fetchedAt: fetchedAt)
        )

        XCTAssertEqual(result.bars.count, 1)
        XCTAssertEqual(result.bars[0].label, "Pro")
        XCTAssertEqual(result.bars[0].used, 0.9, accuracy: 0.0001)
    }

    func testGeminiUsageParserParsesTierNames() throws {
        let paidTier = Data(#"{"paidTier":{"id":"g1-pro-tier"}}"#.utf8)
        XCTAssertEqual(GeminiUsageParser.parseTier(paidTier), "Paid")

        let standardTier = Data(#"{"currentTier":{"id":"standard-tier","name":"Standard"}}"#.utf8)
        XCTAssertEqual(GeminiUsageParser.parseTier(standardTier), "Code Assist")
    }

    func testGeminiUsageParserReadsCodeAssistProject() throws {
        let payload = Data(
            #"{"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":"gen-lang-client-123"}"#.utf8
        )
        let info = try XCTUnwrap(GeminiUsageParser.parseCodeAssist(payload))
        XCTAssertEqual(info.tierName, "Code Assist")
        XCTAssertEqual(info.projectID, "gen-lang-client-123")
    }

    func testGeminiUsageParserReadsObjectShapedCodeAssistProject() throws {
        let byID = Data(
            #"{"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":{"id":"gen-lang-client-obj"}}"#.utf8
        )
        XCTAssertEqual(
            GeminiUsageParser.parseCodeAssist(byID)?.projectID,
            "gen-lang-client-obj"
        )

        let byProjectId = Data(
            #"{"paidTier":{"id":"g1-pro-tier","name":"Paid"},"cloudaicompanionProject":{"projectId":"workspace-project"}}"#.utf8
        )
        let info = try XCTUnwrap(GeminiUsageParser.parseCodeAssist(byProjectId))
        XCTAssertEqual(info.tierName, "Paid")
        XCTAssertEqual(info.projectID, "workspace-project")
    }

    func testGeminiUsageParserPrefersGenLangClientFromResourceManager() throws {
        let payload = Data(
            """
            {
              "projects": [
                {"projectId":"other-gcp-project","lifecycleState":"ACTIVE"},
                {"projectId":"gen-lang-client-999","lifecycleState":"ACTIVE"},
                {"projectId":"deleted-project","lifecycleState":"DELETE_REQUESTED"}
              ]
            }
            """.utf8
        )
        XCTAssertEqual(
            GeminiUsageParser.parseResourceManagerProjectID(payload),
            "gen-lang-client-999"
        )
    }

    func testGeminiUsageParserPrefersGenerativeLanguageLabeledProject() throws {
        let payload = Data(
            """
            {
              "projects": [
                {"projectId":"unrelated-first","lifecycleState":"ACTIVE"},
                {
                  "projectId":"code-assist-project",
                  "lifecycleState":"ACTIVE",
                  "labels":{"generative-language":"true"}
                },
                {"projectId":"gen-lang-client-later","lifecycleState":"ACTIVE"}
              ]
            }
            """.utf8
        )
        XCTAssertEqual(
            GeminiUsageParser.parseResourceManagerProjectID(payload),
            "code-assist-project"
        )
    }

    func testGeminiUsageParserResourceManagerPageExposesNextTokenWithoutPreferred() throws {
        let payload = Data(
            """
            {
              "projects": [
                {"projectId":"unrelated-first","lifecycleState":"ACTIVE"}
              ],
              "nextPageToken": "page-2"
            }
            """.utf8
        )
        let page = try XCTUnwrap(GeminiUsageParser.parseResourceManagerProjectPage(payload))
        XCTAssertNil(page.preferredProjectID)
        XCTAssertEqual(page.firstActiveProjectID, "unrelated-first")
        XCTAssertEqual(page.nextPageToken, "page-2")
        XCTAssertNil(GeminiUsageParser.parseResourceManagerProjectID(payload))
    }

    func testGeminiUsageParserPrefersPaidTierName() throws {
        let payload = Data(
            #"{"paidTier":{"id":"custom-paid-tier","name":"Google AI Ultra"},"currentTier":{"id":"free-tier","name":"Free"}}"#.utf8
        )
        XCTAssertEqual(GeminiUsageParser.parseTier(payload), "Google AI Ultra")
    }

    func testGeminiCLISettingsDetectsNonOAuthAuthMode() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settingsPath = directory.appendingPathComponent("settings.json").path
        try """
        {
          "security": {
            "auth": {
              "selectedType": "gemini-api-key"
            }
          }
        }
        """.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        XCTAssertFalse(GeminiCLISettings.usesOAuthCredentials(at: settingsPath))
    }

    func testGeminiCLISettingsRejectsADCAndGatewayAuthModes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for authType in [
            "compute-default-credentials",
            "cloud-shell",
            "gateway",
            "vertex-ai",
        ] {
            let settingsPath = directory.appendingPathComponent("settings-\(authType).json").path
            try """
            {
              "security": {
                "auth": {
                  "selectedType": "\(authType)"
                }
              }
            }
            """.write(toFile: settingsPath, atomically: true, encoding: .utf8)

            XCTAssertFalse(
                GeminiCLISettings.usesOAuthCredentials(at: settingsPath),
                "Expected \(authType) to be treated as non-OAuth"
            )
        }
    }

    func testGeminiCLISettingsHonorsLegacySelectedAuthType() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let settingsPath = directory.appendingPathComponent("settings.json").path
        try """
        {
          "selectedAuthType": "gemini-api-key"
        }
        """.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        XCTAssertFalse(GeminiCLISettings.usesOAuthCredentials(at: settingsPath))
    }

    func testGeminiUsageProviderRefreshesExpiredTokenAndPersistsCredentials() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "expired-access-token",
          "refresh_token": "redacted-refresh-token",
          "expiry_date": 1000
        }
        """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
        _ = chmod(oauthFilePath, 0o600)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = GeminiUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            oauthFilePath: oauthFilePath,
            quotaEndpoint: URL(string: "https://example.test/gemini-quota")!,
            tierEndpoint: URL(string: "https://example.test/gemini-tier")!,
            tokenEndpoint: URL(string: "https://example.test/gemini-token")!,
            now: { now }
        )
        var requestCount = 0

        MockURLProtocol.handler = { request in
            requestCount += 1
            let url = try XCTUnwrap(request.url)
            if url.path == "/gemini-token" {
                XCTAssertEqual(request.httpMethod, "POST")
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access-token","refresh_token":"new-refresh-token","expires_in":3600}"#.utf8)
                )
            }

            if url.path == "/gemini-tier" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"currentTier":{"id":"standard-tier"}}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access-token")
            let persisted = try XCTUnwrap(GeminiAuthFileStore.readCredentials(at: oauthFilePath))
            XCTAssertEqual(persisted.accessToken, "new-access-token")
            XCTAssertEqual(persisted.refreshToken, "new-refresh-token")
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"{"buckets":[{"tokenType":"REQUESTS","modelId":"gemini-2.5-pro","remainingFraction":0.8,"resetTime":"2026-07-17T12:00:00Z"}]}"#.utf8
                )
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .gemini))

        XCTAssertGreaterThanOrEqual(requestCount, 2)
        XCTAssertEqual(result.bars.count, 1)
        XCTAssertEqual(result.bars[0].label, "Pro (Code Assist)")
    }

    func testGeminiUsageProviderMarksTransientTokenRefreshFailuresIncomplete() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "expired-access-token",
          "refresh_token": "redacted-refresh-token",
          "expiry_date": 1000
        }
        """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
        _ = chmod(oauthFilePath, 0o600)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = GeminiUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            oauthFilePath: oauthFilePath,
            quotaEndpoint: URL(string: "https://example.test/gemini-quota")!,
            tierEndpoint: URL(string: "https://example.test/gemini-tier")!,
            tokenEndpoint: URL(string: "https://example.test/gemini-token")!,
            now: { now }
        )

        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .gemini))

        XCTAssertTrue(result.isIncompleteRefresh)
        XCTAssertEqual(result.subtitle, "Gemini token refresh failed temporarily. Try again later.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testGeminiUsageProviderFetchesQuotaFromOAuthFile() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "redacted-access-token",
          "refresh_token": "redacted-refresh-token",
          "expiry_date": 4102444800000
        }
        """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
        _ = chmod(oauthFilePath, 0o600)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = GeminiUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            oauthFilePath: oauthFilePath,
            quotaEndpoint: URL(string: "https://example.test/gemini-quota")!,
            tierEndpoint: URL(string: "https://example.test/gemini-tier")!,
            now: { now }
        )

        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/gemini-tier" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(
                        #"{"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":"gen-lang-client-123"}"#.utf8
                    )
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer redacted-access-token")
            let body = try XCTUnwrap(String(data: try XCTUnwrap(requestBodyData(from: request)), encoding: .utf8))
            XCTAssertTrue(body.contains(#""project":"gen-lang-client-123""#))
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"{"buckets":[{"tokenType":"REQUESTS","modelId":"gemini-2.5-pro","remainingFraction":0.8,"resetTime":"2026-07-17T12:00:00Z"},{"tokenType":"REQUESTS","modelId":"gemini-2.5-flash","remainingFraction":0.5,"resetTime":"2026-07-17T12:00:00Z"}]}"#.utf8
                )
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .gemini))

        XCTAssertEqual(result.bars.count, 2)
        XCTAssertEqual(result.bars[0].label, "Pro (Code Assist)")
        XCTAssertEqual(result.bars[0].used, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result.bars[1].label, "Flash")
        XCTAssertEqual(result.subtitle, "Live Gemini CLI usage")
    }

    func testGeminiUsageProviderDiscoversProjectViaResourceManager() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "redacted-access-token",
          "refresh_token": "redacted-refresh-token",
          "expiry_date": 4102444800000
        }
        """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
        _ = chmod(oauthFilePath, 0o600)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = GeminiUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            oauthFilePath: oauthFilePath,
            quotaEndpoint: URL(string: "https://example.test/gemini-quota")!,
            tierEndpoint: URL(string: "https://example.test/gemini-tier")!,
            projectsEndpoint: URL(string: "https://example.test/gemini-projects")!,
            now: { now }
        )

        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/gemini-tier" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"currentTier":{"id":"standard-tier"}}"#.utf8)
                )
            }

            if url.path == "/gemini-projects" {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer redacted-access-token")
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(
                        #"{"projects":[{"projectId":"gen-lang-client-discovered","lifecycleState":"ACTIVE"}]}"#.utf8
                    )
                )
            }

            XCTAssertEqual(url.path, "/gemini-quota")
            let body = try XCTUnwrap(String(data: try XCTUnwrap(requestBodyData(from: request)), encoding: .utf8))
            XCTAssertTrue(body.contains(#""project":"gen-lang-client-discovered""#))
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"{"buckets":[{"tokenType":"REQUESTS","modelId":"gemini-2.5-pro","remainingFraction":0.7,"resetTime":"2026-07-17T12:00:00Z"}]}"#.utf8
                )
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .gemini))

        XCTAssertEqual(result.bars.count, 1)
        XCTAssertEqual(result.bars[0].label, "Pro (Code Assist)")
        XCTAssertEqual(result.bars[0].used, 0.3, accuracy: 0.0001)
    }

    func testGeminiUsageProviderPagesResourceManagerUntilPreferredProject() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "redacted-access-token",
          "refresh_token": "redacted-refresh-token",
          "expiry_date": 4102444800000
        }
        """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
        _ = chmod(oauthFilePath, 0o600)

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = GeminiUsageProvider(
            session: URLSession(configuration: sessionConfiguration),
            oauthFilePath: oauthFilePath,
            quotaEndpoint: URL(string: "https://example.test/gemini-quota")!,
            tierEndpoint: URL(string: "https://example.test/gemini-tier")!,
            projectsEndpoint: URL(string: "https://example.test/gemini-projects")!,
            now: { now }
        )

        var projectPageRequests = 0
        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/gemini-tier" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"currentTier":{"id":"standard-tier"}}"#.utf8)
                )
            }

            if url.path == "/gemini-projects" {
                projectPageRequests += 1
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                let token = components?.queryItems?.first(where: { $0.name == "pageToken" })?.value
                if token == nil {
                    return (
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data(
                            #"{"projects":[{"projectId":"unrelated-first","lifecycleState":"ACTIVE"}],"nextPageToken":"page-2"}"#.utf8
                        )
                    )
                }

                XCTAssertEqual(token, "page-2")
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(
                        #"{"projects":[{"projectId":"gen-lang-client-page-2","lifecycleState":"ACTIVE"}]}"#.utf8
                    )
                )
            }

            let body = try XCTUnwrap(String(data: try XCTUnwrap(requestBodyData(from: request)), encoding: .utf8))
            XCTAssertTrue(body.contains(#""project":"gen-lang-client-page-2""#))
            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"{"buckets":[{"tokenType":"REQUESTS","modelId":"gemini-2.5-pro","remainingFraction":0.6,"resetTime":"2026-07-17T12:00:00Z"}]}"#.utf8
                )
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .gemini))

        XCTAssertEqual(projectPageRequests, 2)
        XCTAssertEqual(result.bars.count, 1)
        XCTAssertEqual(result.bars[0].used, 0.4, accuracy: 0.0001)
    }

    func testLocalCredentialDiscoveryIgnoresStaleGeminiOAuthWhenCLIUsesAPIKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthPath = directory.appendingPathComponent("oauth_creds.json").path
        let settingsPath = directory.appendingPathComponent("settings.json").path
        try """
        {
          "access_token": "redacted-access-token",
          "refresh_token": "redacted-refresh-token",
          "expiry_date": 4102444800000
        }
        """.write(toFile: oauthPath, atomically: true, encoding: .utf8)
        try """
        {
          "selectedAuthType": "gemini-api-key"
        }
        """.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        let discovery = LocalCredentialDiscovery.discover(
            geminiOAuthPath: oauthPath,
            geminiSettingsPath: settingsPath,
            ghStatusRunner: { (0, "", "") }
        )

        XCTAssertFalse(discovery.geminiOAuthAvailable)
    }

    func testLocalCredentialDiscoveryDefaultPathsExpandHome() {
        let claudePath = LocalCredentialDiscovery.defaultClaudeCredentialsPath()
        XCTAssertTrue(claudePath.hasSuffix("/.claude/.credentials.json"))
        XCTAssertFalse(claudePath.contains("~"))

        let codexPath = LocalCredentialDiscovery.defaultCodexAuthPath()
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !codexHome.isEmpty {
            let expected = URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent("auth.json")
                .path
            XCTAssertEqual(codexPath, expected)
        } else {
            XCTAssertTrue(codexPath.hasSuffix("/.codex/auth.json"))
            XCTAssertFalse(codexPath.contains("~"))
        }

        let geminiPath = LocalCredentialDiscovery.defaultGeminiOAuthPath()
        if let geminiHome = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !geminiHome.isEmpty {
            let expected = URL(fileURLWithPath: geminiHome, isDirectory: true)
                .appendingPathComponent(".gemini/oauth_creds.json")
                .path
            XCTAssertEqual(geminiPath, expected)
        } else {
            XCTAssertTrue(geminiPath.hasSuffix("/.gemini/oauth_creds.json"))
            XCTAssertFalse(geminiPath.contains("~"))
        }
    }

    func testGeminiHomeDirectoryHonorsGEMINI_CLI_HOME() {
        let customHome = "/tmp/custom-gemini-home"
        let resolved = LocalCredentialDiscovery.geminiHomeDirectory(
            environment: ["GEMINI_CLI_HOME": "  \(customHome)  "]
        )
        XCTAssertEqual(resolved.path, customHome)

        let fallback = LocalCredentialDiscovery.geminiHomeDirectory(environment: [:])
        XCTAssertEqual(fallback, FileManager.default.homeDirectoryForCurrentUser)
    }

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

    private func makeLoopbackCallbackServer(
        preferredPorts: [UInt16],
        maximumRequestLength: Int = 8_192
    ) async throws -> LoopbackOAuthCallbackServer<ClaudeWebAuthService.AuthError> {
        try await LoopbackOAuthCallbackServer<ClaudeWebAuthService.AuthError>.start(
            preferredPorts: preferredPorts,
            expectedState: "expected-state",
            callbackPath: "/callback",
            bindHost: .ipv4,
            queueLabel: "com.hemsoft.CodexBarMacTests.loopbackOAuth.\(UUID().uuidString)",
            couldNotStartError: .couldNotStartCallbackServer,
            missingCodeError: .missingAuthorizationCode,
            stateMismatchError: .stateMismatch,
            timeoutError: .callbackTimedOut,
            successHeading: "Sign-in complete",
            failureHeading: "Sign-in failed",
            maximumRequestLength: maximumRequestLength
        )
    }

    private func sendRawHTTPRequest(
        port: UInt16,
        chunks: [Data],
        finishWriting: Bool = false
    ) async throws -> String {
        try await Task.detached {
            let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            defer { Darwin.close(socketDescriptor) }

            var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
            guard setsockopt(
                socketDescriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &receiveTimeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connectionResult = withUnsafePointer(to: &address) { addressPointer in
                addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(
                        socketDescriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard connectionResult == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            for (index, chunk) in chunks.enumerated() {
                try chunk.withUnsafeBytes { bytes in
                    var sentByteCount = 0
                    while sentByteCount < bytes.count {
                        let result = Darwin.send(
                            socketDescriptor,
                            bytes.baseAddress?.advanced(by: sentByteCount),
                            bytes.count - sentByteCount,
                            0
                        )
                        guard result > 0 else {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        sentByteCount += result
                    }
                }
                if index < chunks.count - 1 {
                    usleep(50_000)
                }
            }

            if finishWriting {
                guard Darwin.shutdown(socketDescriptor, SHUT_WR) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }

            var response = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while true {
                let receivedByteCount = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.recv(socketDescriptor, bytes.baseAddress, bytes.count, 0)
                }
                if receivedByteCount > 0 {
                    response.append(contentsOf: buffer.prefix(receivedByteCount))
                } else if receivedByteCount == 0 {
                    break
                } else if errno == ECONNRESET, !response.isEmpty {
                    break
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            return String(decoding: response, as: UTF8.self)
        }.value
    }
}

private struct StubUsageProvider: UsageProvider {
    let providerID: ProviderID
    let result: ProviderUsageResult

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        result
    }
}

@MainActor
private final class StubUsageAlertNotifier: UsageAlertNotifying {
    deinit {}

    func requestAuthorization() async -> Bool {
        true
    }

    func deliver(_ notification: UsageAlertNotification) async throws {}
}

private final class FailingSecretStore: SecretStore, @unchecked Sendable {
    func readSecret(account: String) throws -> String? {
        nil
    }

    func saveSecret(_ secret: String, account: String) throws {
        throw KeychainError.unhandledStatus(errSecDuplicateItem)
    }

    func deleteSecret(account: String) throws {}
}

private final class CopilotResolvedUsernameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    private var wasSet = false

    var wasCalled: Bool {
        lock.withLock { wasSet }
    }

    var value: String? {
        get { lock.withLock { stored } }
        set {
            lock.withLock {
                stored = newValue
                wasSet = true
            }
        }
    }
}

private final class CopilotTokenResolverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int {
        lock.withLock { count }
    }

    func nextToken() -> String {
        lock.withLock {
            count += 1
            return count == 1 ? "stale-token" : "fresh-token"
        }
    }
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer {
        stream.close()
    }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
        buffer.deallocate()
    }

    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read < 0 {
            return nil
        }
        if read == 0 {
            break
        }
        data.append(buffer, count: read)
    }

    return data
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

private extension String {
    func base64URLEncodedForTest() -> String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
