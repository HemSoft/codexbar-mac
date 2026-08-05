import XCTest
import CryptoKit
import Darwin
import Security
@testable import CodexBarMac

final class GeminiProviderTests: XCTestCase {
    deinit {}

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

    func testGeminiUsageProviderPreservesCredentialsRefreshedExternallyDuringRequest() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "expired-access-token",
          "refresh_token": "original-refresh-token",
          "expiry_date": 1000,
          "id_token": "original-id-token",
          "account": "preserved-metadata"
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
            if url.path == "/gemini-token" {
                try """
                {
                  "access_token": "external-access-token",
                  "refresh_token": "external-refresh-token",
                  "expiry_date": 4102444800000,
                  "id_token": "external-id-token",
                  "account": "preserved-metadata"
                }
                """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
                _ = chmod(oauthFilePath, 0o600)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"response-access-token","expires_in":3600}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer external-access-token")
            if url.path == "/gemini-tier" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(
                        #"{"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":"gen-lang-client-123"}"#.utf8
                    )
                )
            }

            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"{"buckets":[{"tokenType":"REQUESTS","modelId":"gemini-2.5-pro","remainingFraction":0.8,"resetTime":"2026-07-17T12:00:00Z"}]}"#.utf8
                )
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .gemini))

        XCTAssertEqual(result.bars.count, 1)
        let persisted = try XCTUnwrap(GeminiAuthFileStore.readCredentials(at: oauthFilePath))
        XCTAssertEqual(persisted.accessToken, "external-access-token")
        XCTAssertEqual(persisted.refreshToken, "external-refresh-token")
        XCTAssertEqual(persisted.idToken, "external-id-token")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: oauthFilePath)))
                as? [String: Any]
        )
        XCTAssertEqual(root["account"] as? String, "preserved-metadata")
        let attributes = try FileManager.default.attributesOfItem(atPath: oauthFilePath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testGeminiUsageProviderAdoptsExternalRefreshBeforeRejectingOldRefreshToken() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "expired-access-token",
          "refresh_token": "original-refresh-token",
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
            if url.path == "/gemini-token" {
                try """
                {
                  "access_token": "external-access-token",
                  "refresh_token": "external-refresh-token",
                  "expiry_date": 4102444800000,
                  "id_token": "external-id-token"
                }
                """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
                _ = chmod(oauthFilePath, 0o600)
                return (
                    HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":"invalid_grant"}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer external-access-token")
            if url.path == "/gemini-tier" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(
                        #"{"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":"gen-lang-client-123"}"#.utf8
                    )
                )
            }

            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"{"buckets":[{"tokenType":"REQUESTS","modelId":"gemini-2.5-pro","remainingFraction":0.8,"resetTime":"2026-07-17T12:00:00Z"}]}"#.utf8
                )
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .gemini))

        XCTAssertEqual(result.bars.count, 1)
        let persisted = try XCTUnwrap(GeminiAuthFileStore.readCredentials(at: oauthFilePath))
        XCTAssertEqual(persisted.accessToken, "external-access-token")
        XCTAssertEqual(persisted.refreshToken, "external-refresh-token")
        XCTAssertEqual(persisted.idToken, "external-id-token")
    }

    func testGeminiUsageProviderPreservesMissingFieldsWhenAdoptingExternalAccessToken() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "expired-access-token",
          "refresh_token": "original-refresh-token",
          "expiry_date": 1000,
          "id_token": "original-id-token",
          "account": "preserved-metadata"
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
            if url.path == "/gemini-token" {
                try """
                {
                  "access_token": "external-access-token",
                  "expiry_date": 4102444800000,
                  "account": "preserved-metadata"
                }
                """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
                _ = chmod(oauthFilePath, 0o600)
                return (
                    HTTPURLResponse(url: url, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"error":"invalid_grant"}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer external-access-token")
            if url.path == "/gemini-tier" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(
                        #"{"currentTier":{"id":"standard-tier"},"cloudaicompanionProject":"gen-lang-client-123"}"#.utf8
                    )
                )
            }

            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(
                    #"{"buckets":[{"tokenType":"REQUESTS","modelId":"gemini-2.5-pro","remainingFraction":0.8,"resetTime":"2026-07-17T12:00:00Z"}]}"#.utf8
                )
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .gemini))

        XCTAssertEqual(result.bars.count, 1)
        let persisted = try XCTUnwrap(GeminiAuthFileStore.readCredentials(at: oauthFilePath))
        XCTAssertEqual(persisted.accessToken, "external-access-token")
        XCTAssertEqual(persisted.refreshToken, "original-refresh-token")
        XCTAssertEqual(persisted.idToken, "original-id-token")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: oauthFilePath)))
                as? [String: Any]
        )
        XCTAssertEqual(root["account"] as? String, "preserved-metadata")
    }

    func testGeminiUsageProviderDoesNotReuseRejectedAccessTokenAfterMetadataOnlyUpdate() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "rejected-access-token",
          "refresh_token": "original-refresh-token",
          "expiry_date": 4102444800000,
          "id_token": "original-id-token"
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
        var quotaRequestCount = 0

        MockURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/gemini-token" {
                try """
                {
                  "access_token": "rejected-access-token",
                  "refresh_token": "external-refresh-token",
                  "expiry_date": 4102444800000,
                  "id_token": "external-id-token"
                }
                """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
                _ = chmod(oauthFilePath, 0o600)
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"response-access-token","expires_in":3600}"#.utf8)
                )
            }

            if url.path == "/gemini-tier" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"currentTier":{"id":"standard-tier"}}"#.utf8)
                )
            }

            if url.path == "/gemini-quota" {
                quotaRequestCount += 1
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer rejected-access-token")
                return (
                    HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }

            return (
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"projects":[]}"#.utf8)
            )
        }
        defer { MockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: .defaultConfiguration(for: .gemini))

        XCTAssertEqual(quotaRequestCount, 1)
        XCTAssertTrue(result.isIncompleteRefresh)
        XCTAssertEqual(result.subtitle, "Gemini token refresh failed temporarily. Try again later.")
        let persisted = try XCTUnwrap(GeminiAuthFileStore.readCredentials(at: oauthFilePath))
        XCTAssertEqual(persisted.accessToken, "rejected-access-token")
        XCTAssertEqual(persisted.refreshToken, "external-refresh-token")
        XCTAssertEqual(persisted.idToken, "external-id-token")
    }

    func testGeminiAuthFileStoreConditionalWritePreservesPostCheckExternalUpdate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oauthFilePath = directory.appendingPathComponent("oauth_creds.json").path
        try """
        {
          "access_token": "original-access-token",
          "refresh_token": "original-refresh-token",
          "expiry_date": 4102444800000,
          "id_token": "original-id-token",
          "account": "preserved-metadata"
        }
        """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
        _ = chmod(oauthFilePath, 0o600)
        let original = try XCTUnwrap(GeminiAuthFileStore.readCredentials(at: oauthFilePath))

        try """
        {
          "access_token": "external-access-token",
          "refresh_token": "external-refresh-token",
          "expiry_date": 4102444800000,
          "id_token": "external-id-token",
          "account": "preserved-metadata"
        }
        """.write(toFile: oauthFilePath, atomically: true, encoding: .utf8)
        _ = chmod(oauthFilePath, 0o600)

        let result = try GeminiAuthFileStore.writeCredentials(
            GeminiCredentials(
                accessToken: "response-access-token",
                refreshToken: "original-refresh-token",
                expiryDateMs: 4_102_444_800_000,
                idToken: "original-id-token"
            ),
            ifUnchangedFrom: original,
            at: oauthFilePath
        )

        let external = try XCTUnwrap(GeminiAuthFileStore.readCredentials(at: oauthFilePath))
        XCTAssertEqual(result, .changed(external))
        XCTAssertEqual(external.accessToken, "external-access-token")
        XCTAssertEqual(external.refreshToken, "external-refresh-token")
        XCTAssertEqual(external.idToken, "external-id-token")
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: oauthFilePath)))
                as? [String: Any]
        )
        XCTAssertEqual(root["account"] as? String, "preserved-metadata")
        let attributes = try FileManager.default.attributesOfItem(atPath: oauthFilePath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
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
