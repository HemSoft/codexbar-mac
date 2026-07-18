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
}

private struct StubUsageProvider: UsageProvider {
    let providerID: ProviderID
    let result: ProviderUsageResult

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        result
    }
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
