import XCTest
import Darwin
@testable import CodexBarMac

final class CodexBarMacTests: XCTestCase {
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

    func testCodexUsageProviderExplainsUnavailableBrowserFallback() async throws {
        let configuration = ProviderAccountConfiguration(
            providerID: .codex,
            authMethod: .browserSession
        )
        let provider = CodexUsageProvider(now: { Date(timeIntervalSince1970: 2_000_000_000) })

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertTrue(result.subtitle.contains("Browser sign-in is not available on Mac yet"))
        XCTAssertTrue(result.bars.isEmpty)
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
            "utilization": 0.42,
            "resets_at": "2030-01-01T00:00:00Z"
          },
          "seven_day": {
            "utilization": 0.81,
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
            "expiresAt": 1000
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
            credentialsFilePath: credentialsPath
        )
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer claude-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"five_hour":{"utilization":0.25,"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":0.5,"resets_at":"2030-01-08T00:00:00Z"}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .claude))

        XCTAssertEqual(result.bars.map(\.used), [25, 50])
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

private extension String {
    func base64URLEncodedForTest() -> String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
