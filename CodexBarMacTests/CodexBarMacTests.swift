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
}

private final class CopilotResolvedUsernameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
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

private extension String {
    func base64URLEncodedForTest() -> String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
