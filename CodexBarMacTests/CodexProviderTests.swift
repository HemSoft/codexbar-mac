import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class CodexProviderTests: XCTestCase {
    deinit {}

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
        XCTAssertEqual(result.bars.map(\.stableKey), ["window-18000", "window-604800"])
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
        XCTAssertEqual(weeklyOnly.bars.map(\.stableKey), ["window-604800"])

        let driftedPayload = #"{"rate_limit":{"primary_window":{"used_percent":20,"reset_at":1894060800,"limit_window_seconds":604800},"secondary_window":{"used_percent":10,"reset_at":1893456000,"limit_window_seconds":17999}}}"#
        let drifted = try XCTUnwrap(CodexUsageParser.parse(Data(driftedPayload.utf8)))

        XCTAssertEqual(drifted.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(drifted.bars.map(\.stableKey), ["window-18000", "window-604800"])

        let outsideTolerancePayload = #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1893456000,"limit_window_seconds":18901}}}"#
        let outsideTolerance = try XCTUnwrap(CodexUsageParser.parse(Data(outsideTolerancePayload.utf8)))

        XCTAssertEqual(outsideTolerance.bars.map(\.label), ["315 minute usage limit"])
        XCTAssertEqual(outsideTolerance.bars.map(\.stableKey), ["window-18901"])
    }

    func testCodexUsageParserReadsEveryRateLimitBucketDeterministically() throws {
        let payload = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 30,
              "reset_at": 1894060800,
              "limit_window_seconds": 604800
            },
            "secondary_window": null
          },
          "code_review_rate_limit": {
            "primary_window": {
              "used_percent": 12,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            }
          },
          "additional_rate_limits": [
            null,
            {
              "metered_feature": "codex_future",
              "limit_name": "Future model",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 7,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 7200
                }
              }
            },
            {"metered_feature": "malformed", "rate_limit": "unexpected"},
            {
              "metered_feature": "codex_bengalfox",
              "limit_name": "GPT-5.3-Codex-Spark",
              "rate_limit": {
                "secondary_window": {
                  "used_percent": 66,
                  "reset_at": 1894060800,
                  "limit_window_seconds": 604800
                },
                "primary_window": {
                  "used_percent": 44,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 18000
                }
              }
            },
            {
              "metered_feature": "codex_quiet",
              "primary_window": {
                "used_percent": 9,
                "reset_at": 1893456000,
                "limit_window_seconds": 9000
              },
              "secondary_window": {"used_percent": "nan"}
            }
          ]
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(
            result.bars.map(\.stableKey),
            [
                "window-604800",
                "bucket-code_5Freview.window-18000",
                "bucket-codex_5Fbengalfox.window-18000",
                "bucket-codex_5Fbengalfox.window-604800",
                "bucket-codex_5Ffuture.window-7200",
                "bucket-codex_5Fquiet.window-9000",
            ]
        )
        XCTAssertEqual(
            result.bars.map(\.label),
            [
                "Weekly usage limit",
                "Code review · 5 hour usage limit",
                "GPT-5.3-Codex-Spark · 5 hour usage limit",
                "GPT-5.3-Codex-Spark · Weekly usage limit",
                "Future model · 2 hour usage limit",
                "Additional Codex usage · 150 minute usage limit",
            ]
        )
        XCTAssertEqual(result.bars.map(\.used), [30, 12, 44, 66, 7, 9])

        var reorderedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        let additionalRateLimits = try XCTUnwrap(reorderedRoot["additional_rate_limits"] as? [Any])
        reorderedRoot["additional_rate_limits"] = Array(additionalRateLimits.reversed())
        let reorderedData = try JSONSerialization.data(withJSONObject: reorderedRoot)
        let reordered = try XCTUnwrap(CodexUsageParser.parse(reorderedData))

        XCTAssertEqual(reordered.bars.map(\.stableKey), result.bars.map(\.stableKey))
        XCTAssertEqual(reordered.bars.map(\.label), result.bars.map(\.label))
        XCTAssertEqual(reordered.bars.map(\.used), result.bars.map(\.used))
    }

    func testCodexUsageParserReadsKeyedAdditionalRateLimits() throws {
        let payload = """
        {
          "additional_rate_limits": {
            "spark": {
              "limit_name": "Spark",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 18000
                }
              }
            },
            "future": {
              "limit_id": "future-id",
              "rate_limit": {
                "secondary_window": {
                  "used_percent": 35,
                  "reset_after_seconds": 600,
                  "window_minutes": 120
                }
              }
            }
          }
        }
        """

        let fetchedAt = Date(timeIntervalSince1970: 2_000_000_000)
        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.bars.map(\.stableKey), [
            "bucket-future.limit-future_2Did.window-7200",
            "bucket-spark.window-18000",
        ])
        XCTAssertEqual(result.bars.map(\.label), [
            "Additional Codex usage · 2 hour usage limit",
            "Spark · 5 hour usage limit",
        ])
        XCTAssertEqual(result.bars.first?.resetsAt, fetchedAt.addingTimeInterval(600))
    }

    func testCodexUsageParserDisambiguatesDuplicateBucketIdentities() throws {
        let payload = """
        {
          "additional_rate_limits": [
            {
              "metered_feature": "foo_bar",
              "primary_window": {
                "used_percent": 1,
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            },
            {
              "metered_feature": "foo-bar",
              "primary_window": {
                "used_percent": 2,
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            },
            {
              "primary_window": {
                "used_percent": 3,
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            },
            {
              "primary_window": {
                "used_percent": 4,
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            },
            {
              "metered_feature": "foo_bar",
              "primary_window": {
                "used_percent": 5,
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            }
          ]
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.count, 5)
        XCTAssertEqual(Set(result.bars.compactMap(\.stableKey)), [
            "bucket-additional.window-3600",
            "bucket-additional.window-3600.duplicate-2",
            "bucket-foo_2Dbar.window-3600",
            "bucket-foo_5Fbar.window-3600",
            "bucket-foo_5Fbar.window-3600.duplicate-2",
        ])

        var reorderedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        )
        let buckets = try XCTUnwrap(reorderedRoot["additional_rate_limits"] as? [Any])
        reorderedRoot["additional_rate_limits"] = Array(buckets.reversed())
        let reordered = try XCTUnwrap(CodexUsageParser.parse(
            try JSONSerialization.data(withJSONObject: reorderedRoot)
        ))
        let keyedUsage = Dictionary(uniqueKeysWithValues: result.bars.compactMap { bar in
            bar.stableKey.map { ($0, bar.used) }
        })
        let reorderedKeyedUsage = Dictionary(uniqueKeysWithValues: reordered.bars.compactMap { bar in
            bar.stableKey.map { ($0, bar.used) }
        })

        XCTAssertEqual(reorderedKeyedUsage, keyedUsage)
    }

    func testCodexUsageParserRejectsUnsafeWindowsWithoutDroppingValidNeighbors() throws {
        let payload = """
        {
          "additional_rate_limits": [
            {
              "metered_feature": "zero",
              "primary_window": {
                "used_percent": 1,
                "reset_at": 1893456000,
                "limit_window_seconds": 0
              }
            },
            {
              "metered_feature": "negative",
              "primary_window": {
                "used_percent": 2,
                "reset_at": 1893456000,
                "limit_window_seconds": -1
              }
            },
            {
              "metered_feature": "extreme",
              "primary_window": {
                "used_percent": 3,
                "reset_at": 1893456000,
                "limit_window_seconds": 1e100
              }
            },
            {
              "metered_feature": "implausibly_long",
              "primary_window": {
                "used_percent": 4,
                "reset_at": 1893456000,
                "limit_window_seconds": 315360001
              }
            },
            {
              "metered_feature": "nonfinite_usage",
              "primary_window": {
                "used_percent": "nan",
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              }
            },
            {
              "metered_feature": "missing_reset",
              "primary_window": {
                "used_percent": 6,
                "limit_window_seconds": 3600
              }
            },
            {
              "metered_feature": "valid",
              "primary_window": {
                "used_percent": 5,
                "reset_at": 1893456000,
                "limit_window_seconds": 3600
              },
              "secondary_window": "malformed"
            }
          ]
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.bars.map(\.stableKey), ["bucket-valid.window-3600"])
        XCTAssertEqual(result.bars.map(\.used), [5])
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

    func testCodexAuthFileStoreSurfacesPermissionRestorationFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let authFilePath = directory.appendingPathComponent("auth.json").path
        var requestedPath: String?
        var requestedMode: mode_t?

        XCTAssertThrowsError(
            try CodexAuthFileStore.writeCredentials(
                CodexCredentials(accessToken: "redacted-access", refreshToken: "redacted-refresh"),
                at: authFilePath,
                settingPermissionsWith: { path, mode in
                    requestedPath = path
                    requestedMode = mode
                    return -1
                }
            )
        ) { error in
            guard case CodexAuthFileStoreError.unableToSecureFile = error else {
                return XCTFail("Expected unableToSecureFile, got \(error)")
            }
        }

        XCTAssertEqual(requestedPath, authFilePath)
        XCTAssertEqual(requestedMode, 0o600)
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

    func testCodexAdditionalBrowserAccountPrefersItsSavedCredential() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let authFilePath = directory.appendingPathComponent("auth.json").path
        defer { try? FileManager.default.removeItem(at: directory) }
        try CodexAuthFileStore.writeCredentials(
            CodexCredentials(accessToken: "shared-local", expiresAt: 2_000_003_600),
            at: authFilePath
        )

        let secretStore = InMemorySecretStore()
        let defaultConfiguration = ProviderAccountConfiguration(
            providerID: .codex,
            authMethod: .browserSession
        )
        let additionalConfiguration = ProviderAccountConfiguration(
            id: "codex.additional",
            providerID: .codex,
            authMethod: .browserSession
        )
        for (configuration, accessToken) in [
            (defaultConfiguration, "default-browser"),
            (additionalConfiguration, "additional-browser"),
        ] {
            try secretStore.saveSecret(
                CodexCredentialsParser.storedCredential(from: CodexCredentials(
                    accessToken: accessToken,
                    expiresAt: 2_000_003_600
                )),
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            authFilePath: authFilePath,
            now: { now }
        )
        var requestedTokens: [String] = []
        MockURLProtocol.handler = { request in
            requestedTokens.append(try XCTUnwrap(request.value(forHTTPHeaderField: "Authorization")))
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":22,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        _ = try await provider.fetchUsage(for: defaultConfiguration)
        _ = try await provider.fetchUsage(for: additionalConfiguration)

        XCTAssertEqual(requestedTokens, ["Bearer shared-local", "Bearer additional-browser"])
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

    func testInjectedRandomBytesPreserveBase64URLAndPKCEBehavior() throws {
        let bytes = Data(repeating: 0xFB, count: 64)
        let expectedVerifier = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let digest = SHA256.hash(data: Data(expectedVerifier.utf8))
        let expectedChallenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let generator: OAuthRandomness.Generator = { byteCount in
            Data(repeating: 0xFB, count: byteCount)
        }

        let codex = try CodexWebAuthService.makePKCEPair(randomBytes: generator)
        let claude = try ClaudeWebAuthService.makePKCEPair(randomBytes: generator)
        let copilot = try CopilotWebAuthService.makePKCEPair(randomBytes: generator)
        let cursor = try CursorWebAuthService.makePKCEPair(randomBytes: generator)

        XCTAssertEqual(codex.codeVerifier, expectedVerifier)
        XCTAssertEqual(codex.codeChallenge, expectedChallenge)
        XCTAssertEqual(claude.codeVerifier, expectedVerifier)
        XCTAssertEqual(claude.codeChallenge, expectedChallenge)
        XCTAssertEqual(copilot.codeVerifier, expectedVerifier)
        XCTAssertEqual(copilot.codeChallenge, expectedChallenge)
        XCTAssertEqual(cursor.codeVerifier, expectedVerifier)
        XCTAssertEqual(cursor.codeChallenge, expectedChallenge)
    }

    @MainActor
    func testCodexSignInStopsBeforeBrowserWhenStateRandomnessFails() async {
        let service = CodexWebAuthService(randomBytes: { _ in
            throw RandomGeneratorTestError.failed
        })
        var didPresentBrowser = false

        do {
            _ = try await service.signIn { _ in
                didPresentBrowser = true
                return true
            }
            XCTFail("Expected ChatGPT sign-in to fail closed.")
        } catch {
            XCTAssertEqual(error as? CodexWebAuthService.AuthError, .secureRandomUnavailable)
            XCTAssertEqual(error.localizedDescription, "ChatGPT sign-in could not start securely. Try again.")
        }
        XCTAssertFalse(didPresentBrowser)
    }

    @MainActor
    func testClaudeSignInStopsBeforeBrowserWhenPKCERandomnessFails() async {
        let service = ClaudeWebAuthService(randomBytes: { byteCount in
            guard byteCount == 32 else {
                throw RandomGeneratorTestError.failed
            }
            return Data(repeating: 0xAB, count: byteCount)
        })
        var didPresentBrowser = false

        do {
            _ = try await service.signIn { _ in
                didPresentBrowser = true
                return true
            }
            XCTFail("Expected Claude sign-in to fail closed.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .secureRandomUnavailable)
            XCTAssertEqual(error.localizedDescription, "Claude sign-in could not start securely. Try again.")
        }
        XCTAssertFalse(didPresentBrowser)
    }

    @MainActor
    func testCopilotSignInStopsBeforeBrowserWhenStateRandomnessFails() async {
        let service = CopilotWebAuthService(randomBytes: { _ in
            throw RandomGeneratorTestError.failed
        })
        let configuration = CopilotOAuthConfiguration(clientID: "client-id", clientSecret: "client-secret")
        var didPresentBrowser = false

        do {
            _ = try await service.signIn(configuration: configuration) { _ in
                didPresentBrowser = true
                return true
            }
            XCTFail("Expected GitHub sign-in to fail closed.")
        } catch {
            XCTAssertEqual(error as? CopilotWebAuthService.AuthError, .secureRandomUnavailable)
            XCTAssertEqual(error.localizedDescription, "GitHub sign-in could not start securely. Try again.")
        }
        XCTAssertFalse(didPresentBrowser)
    }

    @MainActor
    func testCursorSignInStopsBeforeBrowserAndPollingWhenPKCERandomnessFails() async {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        defer { session.invalidateAndCancel() }
        MockURLProtocol.handler = { _ in
            XCTFail("Token polling must not start without a secure PKCE verifier.")
            throw URLError(.badServerResponse)
        }
        defer { MockURLProtocol.handler = nil }
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1,
            randomBytes: { _ in throw RandomGeneratorTestError.failed }
        )
        var didPresentBrowser = false

        do {
            _ = try await service.signIn { _ in
                didPresentBrowser = true
                return true
            }
            XCTFail("Expected Cursor sign-in to fail closed.")
        } catch {
            XCTAssertEqual(error as? CursorWebAuthService.AuthError, .secureRandomUnavailable)
            XCTAssertEqual(error.localizedDescription, "Cursor sign-in could not start securely. Try again.")
        }
        XCTAssertFalse(didPresentBrowser)
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
        let validResponse = try await sendRawHTTPRequest(
            port: port,
            chunks: [validLoopbackCallbackRequest(code: "a")]
        )
        let callbackURL = try await callbackTask.value

        XCTAssertTrue(validResponse.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(callbackURL.path, "/callback")
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
        let validResponse = try await sendRawHTTPRequest(
            port: port,
            chunks: [validLoopbackCallbackRequest()]
        )
        let callbackURL = try await callbackTask.value

        XCTAssertTrue(validResponse.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(callbackURL.path, "/callback")
    }

    func testLoopbackOAuthCallbackServerIgnoresInvalidRequestsUntilValidCallback() async throws {
        let port: UInt16 = 36_192
        let server = try await makeLoopbackCallbackServer(preferredPorts: [port])
        defer { server.cancel() }
        let callbackTask = Task {
            try await server.waitForCallback(timeoutNanoseconds: 2_000_000_000)
        }
        let invalidRequests = [
            "POST /callback?code=authorization-code&state=expected-state HTTP/1.1\r\n\r\n",
            "GET /callback/stale?code=authorization-code&state=expected-state HTTP/1.1\r\n\r\n",
            "GET /callback?code=authorization-code&state=wrong-state HTTP/1.1\r\n\r\n",
            "GET /callback?state=expected-state HTTP/1.1\r\n\r\n",
        ]

        for request in invalidRequests {
            let response = try await sendRawHTTPRequest(
                port: port,
                chunks: [Data(request.utf8)]
            )
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request"))
        }

        let validResponse = try await sendRawHTTPRequest(
            port: port,
            chunks: [validLoopbackCallbackRequest()]
        )
        let callbackURL = try await callbackTask.value

        XCTAssertTrue(validResponse.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertEqual(
            URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
                .queryItemValue(named: "code"),
            "authorization-code"
        )
    }

    func testLoopbackOAuthCallbackServerInvalidTrafficDoesNotPreventTimeout() async throws {
        let port: UInt16 = 36_193
        let server = try await makeLoopbackCallbackServer(preferredPorts: [port])
        defer { server.cancel() }

        for _ in 0..<3 {
            let response = try await sendRawHTTPRequest(
                port: port,
                chunks: [Data("GET /callback?code=authorization-code&state=wrong-state HTTP/1.1\r\n\r\n".utf8)]
            )
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request"))
        }

        let callbackTask = Task {
            try await server.waitForCallback(timeoutNanoseconds: 500_000_000)
        }
        do {
            _ = try await callbackTask.value
            XCTFail("Expected invalid callback traffic to leave the configured timeout in effect.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .callbackTimedOut)
        }
    }

    func testLoopbackOAuthCallbackServerInvalidTrafficDoesNotPreventCancellation() async throws {
        let port: UInt16 = 36_194
        let server = try await makeLoopbackCallbackServer(preferredPorts: [port])
        defer { server.cancel() }
        let callbackTask = Task {
            try await server.waitForCallback(timeoutNanoseconds: 2_000_000_000)
        }

        for _ in 0..<2 {
            let response = try await sendRawHTTPRequest(
                port: port,
                chunks: [Data("GET /wrong-path HTTP/1.1\r\n\r\n".utf8)]
            )
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request"))
        }

        async let heldConnectionResponse = sendRawHTTPRequest(
            port: port,
            chunks: [Data("GET /callback?code=incomplete".utf8)]
        )
        try await Task.sleep(nanoseconds: 50_000_000)
        server.cancel()

        do {
            _ = try await callbackTask.value
            XCTFail("Expected cancellation to finish the pending callback task.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .missingAuthorizationCode)
        }
        let closedConnectionResponse = try await heldConnectionResponse
        XCTAssertTrue(closedConnectionResponse.isEmpty)
    }

    func testLoopbackOAuthCallbackServerCompletesFailureForProviderDenial() async throws {
        let port: UInt16 = 36_195
        let server = try await makeLoopbackCallbackServer(preferredPorts: [port])
        defer { server.cancel() }
        let callbackTask = Task {
            try await server.waitForCallback(timeoutNanoseconds: 2_000_000_000)
        }

        let response = try await sendRawHTTPRequest(
            port: port,
            chunks: [Data("GET /callback?error=access_denied&state=expected-state HTTP/1.1\r\n\r\n".utf8)]
        )

        XCTAssertTrue(response.hasPrefix("HTTP/1.1 400 Bad Request"))
        do {
            _ = try await callbackTask.value
            XCTFail("Expected a provider denial to finish the pending callback with an error.")
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

    @MainActor
    func testCodexBrowserSignInExchangesCallbackForCredentials() async throws {
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_synthetic"}}"#
            .base64URLEncodedForTest()
        let idToken = "\(header).\(payload).redacted-signature"
        let responseBody = try JSONSerialization.data(withJSONObject: [
            "access_token": "redacted-access-token",
            "refresh_token": "redacted-refresh-token",
            "id_token": idToken,
            "expires_at": 2_000_003_600,
        ])

        let result = try await performCodexTokenExchange(responseBody: responseBody) { request, authorizationURL in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Type"),
                "application/x-www-form-urlencoded"
            )
            let authorization = try XCTUnwrap(
                URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)
            )
            let redirectURI = try XCTUnwrap(authorization.queryItemValue(named: "redirect_uri"))
            XCTAssertEqual(authorization.queryItemValue(named: "state"), deterministicOAuthValue(byteCount: 32))
            XCTAssertEqual(URL(string: redirectURI)?.path, "/auth/callback")

            let body = try formValues(from: requestBodyData(from: request))
            XCTAssertEqual(body["grant_type"], "authorization_code")
            XCTAssertEqual(body["code"], syntheticOAuthCode)
            XCTAssertEqual(body["redirect_uri"], redirectURI)
            XCTAssertEqual(body["client_id"], CodexWebAuthService.clientID)
            XCTAssertEqual(body["code_verifier"], deterministicOAuthValue(byteCount: 64))
        }

        XCTAssertEqual(result.accessToken, "redacted-access-token")
        XCTAssertEqual(result.refreshToken, "redacted-refresh-token")
        XCTAssertEqual(result.idToken, idToken)
        XCTAssertEqual(result.accountID, "acct_synthetic")
        XCTAssertEqual(result.expiresAt, 2_000_003_600)
    }

    @MainActor
    func testCodexBrowserSignInSanitizesNonSuccessTokenResponse() async throws {
        let responseBody = Data(
            #"{"error":"invalid_grant","error_description":"redacted-authorization-code redacted-access-token untrusted detail"}"#.utf8
        )

        do {
            _ = try await performCodexTokenExchange(statusCode: 400, responseBody: responseBody)
            XCTFail("Expected a rejected ChatGPT token exchange.")
        } catch {
            XCTAssertEqual(
                error as? CodexWebAuthService.AuthError,
                .tokenExchangeFailed("HTTP 400 (invalid_grant)")
            )
            XCTAssertFalse(error.localizedDescription.contains(syntheticOAuthCode))
            XCTAssertFalse(error.localizedDescription.contains("redacted-access-token"))
            XCTAssertFalse(error.localizedDescription.contains("untrusted detail"))
        }
    }

    @MainActor
    func testCodexBrowserSignInRejectsMalformedSuccessResponse() async throws {
        do {
            _ = try await performCodexTokenExchange(responseBody: Data(#"{"access_token":42}"#.utf8))
            XCTFail("Expected a malformed ChatGPT token response to fail.")
        } catch {
            XCTAssertEqual(error as? CodexWebAuthService.AuthError, .invalidTokenResponse)
        }
    }

    @MainActor
    func testCodexBrowserSignInRejectsSuccessResponseWithoutAccessToken() async throws {
        do {
            _ = try await performCodexTokenExchange(
                responseBody: Data(#"{"refresh_token":"redacted-refresh-token"}"#.utf8)
            )
            XCTFail("Expected a ChatGPT token response without an access token to fail.")
        } catch {
            XCTAssertEqual(error as? CodexWebAuthService.AuthError, .invalidTokenResponse)
            XCTAssertFalse(error.localizedDescription.contains("redacted-refresh-token"))
        }
    }

    @MainActor
    func testCodexBrowserSignInRejectsOAuthErrorPayloadWithoutSurfacingDetails() async throws {
        let responseBody = Data(
            #"{"error":"access_denied","error_description":"redacted-authorization-code untrusted denial"}"#.utf8
        )

        do {
            _ = try await performCodexTokenExchange(responseBody: responseBody)
            XCTFail("Expected an OAuth error payload to fail ChatGPT sign-in.")
        } catch {
            XCTAssertEqual(error as? CodexWebAuthService.AuthError, .invalidTokenResponse)
            XCTAssertFalse(error.localizedDescription.contains(syntheticOAuthCode))
            XCTAssertFalse(error.localizedDescription.contains("untrusted denial"))
        }
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

}
