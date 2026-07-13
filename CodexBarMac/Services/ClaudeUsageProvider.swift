import Foundation

public final class ClaudeUsageProvider: UsageProvider {
    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenRefreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let messagesEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let probeBody = """
    {"model":"claude-haiku-4-5","max_tokens":1,"messages":[{"role":"user","content":"x"}]}
    """

    private let secretStore: any SecretStore
    private let session: URLSession
    private let credentialsFilePath: String
    private let keychainAccount: String
    private let now: @Sendable () -> Date
    private let snapshotCache = ClaudeUsageSnapshotCache()

    public let providerID = ProviderID.claude

    public init(
        secretStore: any SecretStore = KeychainService(),
        session: URLSession = .shared,
        credentialsFilePath: String = LocalCredentialDiscovery.defaultClaudeCredentialsPath(),
        keychainAccount: String = NSUserName(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.credentialsFilePath = credentialsFilePath
        self.keychainAccount = keychainAccount
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard var loaded = loadCredentials(configuration: configuration) else {
            return failureResult(notConfiguredMessage(for: configuration), configuration: configuration)
        }

        loaded.credentials = try await refreshedCredentialsIfNeeded(
            loaded.credentials,
            storage: loaded.storage,
            configuration: configuration
        )
        guard let token = loaded.credentials.accessToken, !token.isEmpty else {
            return failureResult("Claude credential is missing an access token.", configuration: configuration)
        }
        await snapshotCache.prepare(accountID: configuration.id, credential: token)

        let oauthOutcome = try await fetchOAuthUsage(
            configuration: configuration,
            credentials: loaded.credentials,
            accessToken: token
        )
        if let usageResult = oauthOutcome.result {
            let retryAt = await snapshotCache.retryAt(accountID: configuration.id)
            let canProbe = retryAt.map { $0 <= now() } ?? true
            if canProbe, usageResult.bars.isEmpty {
                do {
                    if let rateLimitResult = try await fetchRateLimitUsage(
                        configuration: configuration,
                        credentials: loaded.credentials,
                        accessToken: token
                    ), !rateLimitResult.bars.isEmpty {
                        await snapshotCache.store(rateLimitResult, accountID: configuration.id)
                        return rateLimitResult
                    }
                } catch {
                    if oauthOutcome.isSuccessfulSnapshot {
                        await snapshotCache.storePreservingBars(usageResult, accountID: configuration.id)
                    }
                    return usageResult
                }
            }
            if oauthOutcome.isSuccessfulSnapshot {
                await snapshotCache.storePreservingBars(usageResult, accountID: configuration.id)
            }
            return usageResult
        }

        if let rateLimitResult = try await fetchRateLimitUsage(
            configuration: configuration,
            credentials: loaded.credentials,
            accessToken: token
        ) {
            return rateLimitResult
        }

        return failureResult("Claude usage did not include rate-limit windows.", configuration: configuration)
    }

    private struct LoadedCredentials {
        var credentials: ClaudeCredentials
        let storage: ClaudeCredentialStore.Storage?
    }

    private func loadCredentials(configuration: ProviderAccountConfiguration) -> LoadedCredentials? {
        if let local = ClaudeCredentialStore.readCredentials(
            keychainAccount: keychainAccount,
            credentialsFilePath: credentialsFilePath
        ) {
            return LoadedCredentials(credentials: local.credentials, storage: local.storage)
        }

        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard
            let storedSecret = try? secretStore.readSecret(account: account),
            let parsedCredentials = ClaudeCredentialsParser.parse(storedSecret),
            parsedCredentials.accessToken?.isEmpty == false
        else {
            return nil
        }

        return LoadedCredentials(credentials: parsedCredentials, storage: nil)
    }

    private func notConfiguredMessage(for configuration: ProviderAccountConfiguration) -> String {
        switch configuration.authMethod {
        case .browserSession:
            "Browser sign-in is not available on Mac yet. Sign in with Claude Code."
        default:
            "Not configured - sign in with Claude Code."
        }
    }

    private func fetchOAuthUsage(
        configuration: ProviderAccountConfiguration,
        credentials: ClaudeCredentials,
        accessToken: String
    ) async throws -> OAuthUsageOutcome {
        let fetchedAt = now()
        if let retryAt = await snapshotCache.retryAt(accountID: configuration.id), retryAt > fetchedAt {
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude usage is rate-limited until \(Self.formatRetryDate(retryAt)).",
                    configuration: configuration
                ),
                permitsFallbackProbe: false
            )
        }

        let (data, response) = try await session.data(for: makeOAuthUsageRequest(accessToken: accessToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            return OAuthUsageOutcome(
                result: failureResult("Claude usage returned an invalid response.", configuration: configuration),
                permitsFallbackProbe: false
            )
        }

        switch httpResponse.statusCode {
        case 200..<300:
            guard let parsed = ClaudeUsageParser.parse(
                data,
                subscriptionType: credentials.subscriptionType,
                fetchedAt: fetchedAt
            ) else {
                return OAuthUsageOutcome(result: nil, permitsFallbackProbe: true)
            }
            let result = applyAccountMetadata(to: parsed, configuration: configuration)
            return OAuthUsageOutcome(
                result: result,
                permitsFallbackProbe: false,
                isSuccessfulSnapshot: true
            )
        case 401:
            return OAuthUsageOutcome(
                result: failureResult("Claude credential was rejected. Sign in again.", configuration: configuration),
                permitsFallbackProbe: false
            )
        case 403:
            return OAuthUsageOutcome(
                result: failureResult("Claude credential lacks permission to read subscription usage.", configuration: configuration),
                permitsFallbackProbe: false
            )
        case 404:
            return OAuthUsageOutcome(
                result: failureResult("Claude subscription usage is unavailable for this account.", configuration: configuration),
                permitsFallbackProbe: true
            )
        case 429:
            let retryAt = retryDate(httpResponse, now: fetchedAt)
                ?? fetchedAt.addingTimeInterval(60)
            await snapshotCache.setRetryAt(retryAt, accountID: configuration.id)
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude usage is rate-limited until \(Self.formatRetryDate(retryAt)).",
                    configuration: configuration
                ),
                permitsFallbackProbe: false
            )
        case 500..<600:
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude usage is temporarily unavailable (server error \(httpResponse.statusCode)).",
                    configuration: configuration
                ),
                permitsFallbackProbe: true
            )
        default:
            return OAuthUsageOutcome(result: nil, permitsFallbackProbe: true)
        }
    }

    private func fetchRateLimitUsage(
        configuration: ProviderAccountConfiguration,
        credentials: ClaudeCredentials,
        accessToken: String
    ) async throws -> ProviderUsageResult? {
        let fetchedAt = now()
        let (_, response) = try await session.data(for: makeRateLimitProbeRequest(accessToken: accessToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }

        guard httpResponse.statusCode != 401 && httpResponse.statusCode != 403 else {
            return failureResult("Claude credential expired or lacks Claude Code access.", configuration: configuration)
        }

        guard let parsed = ClaudeUsageParser.parseRateLimitHeaders(
            httpResponse.allHeaderFields,
            subscriptionType: credentials.subscriptionType,
            fetchedAt: fetchedAt
        ) else {
            return nil
        }

        let result = applyAccountMetadata(to: parsed, configuration: configuration)
        await snapshotCache.store(result, accountID: configuration.id)
        return result
    }

    private func refreshedCredentialsIfNeeded(
        _ credentials: ClaudeCredentials,
        storage: ClaudeCredentialStore.Storage?,
        configuration: ProviderAccountConfiguration
    ) async throws -> ClaudeCredentials {
        guard credentials.expiresAt > 0 else {
            return credentials
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(normalizeEpochToSeconds(credentials.expiresAt)))
        guard expiresAt <= Date() else {
            return credentials
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return credentials
        }

        var request = URLRequest(url: Self.tokenRefreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ])

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let refreshed = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data),
            let accessToken = refreshed.accessToken,
            !accessToken.isEmpty
        else {
            return credentials
        }

        let updated = ClaudeCredentials(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier,
            expiresAt: refreshed.expiresAt ?? refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)).claudeUsageUnixTimeMilliseconds } ?? 0,
            accessToken: accessToken,
            refreshToken: refreshed.refreshToken ?? credentials.refreshToken
        )
        try persistCredentials(updated, storage: storage, configuration: configuration)
        return updated
    }

    private func persistCredentials(
        _ credentials: ClaudeCredentials,
        storage: ClaudeCredentialStore.Storage?,
        configuration: ProviderAccountConfiguration
    ) throws {
        if let storage {
            try ClaudeCredentialStore.saveCredentials(credentials, to: storage)
            return
        }

        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: credentials),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
    }

    private func makeOAuthUsageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: Self.usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("CodexBarMac", forHTTPHeaderField: "X-Client-Name")
        return request
    }

    private func makeRateLimitProbeRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: Self.messagesEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.probeBody.utf8)
        return request
    }

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            fetchedAt: Date()
        )
    }

    private func staleOrFailureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration
    ) async -> ProviderUsageResult {
        guard let cached = await snapshotCache.result(accountID: configuration.id) else {
            return failureResult(message, configuration: configuration)
        }

        return ProviderUsageResult(
            accountID: cached.accountID,
            providerID: cached.providerID,
            title: configuration.displayName,
            subtitle: "\(message) Showing last known data.",
            bars: cached.bars,
            creditsRemaining: cached.creditsRemaining,
            fetchedAt: cached.fetchedAt
        )
    }

    private func retryDate(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard let retryAfter = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = TimeInterval(retryAfter), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        return Self.httpDateFormatter.date(from: retryAfter)
    }

    private static func formatRetryDate(_ date: Date) -> String {
        UserFacingDateTimeFormatter.current.dateAndTime(date)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()

    private func applyAccountMetadata(
        to result: ProviderUsageResult,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: result.providerID,
            title: configuration.displayName,
            subtitle: result.subtitle,
            bars: result.bars,
            creditsRemaining: result.creditsRemaining,
            fetchedAt: result.fetchedAt
        )
    }

    private func normalizeEpochToSeconds(_ value: Int64) -> Int64 {
        value >= 1_000_000_000_000 ? value / 1000 : value
    }
}

private actor ClaudeUsageSnapshotCache {
    private var results: [String: ProviderUsageResult] = [:]
    private var retryDates: [String: Date] = [:]
    private var credentials: [String: String] = [:]

    func prepare(accountID: String, credential: String) {
        guard credentials[accountID] != credential else {
            return
        }
        if credentials[accountID] != nil {
            results[accountID] = nil
            retryDates[accountID] = nil
        }
        credentials[accountID] = credential
    }

    func store(_ result: ProviderUsageResult, accountID: String) {
        results[accountID] = result
        retryDates[accountID] = nil
    }

    func storePreservingBars(_ result: ProviderUsageResult, accountID: String) {
        guard result.bars.isEmpty, let cached = results[accountID], !cached.bars.isEmpty else {
            store(result, accountID: accountID)
            return
        }
        results[accountID] = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: cached.bars,
            creditsRemaining: result.creditsRemaining,
            fetchedAt: cached.fetchedAt
        )
        retryDates[accountID] = nil
    }

    func result(accountID: String) -> ProviderUsageResult? {
        results[accountID]
    }

    func setRetryAt(_ date: Date?, accountID: String) {
        retryDates[accountID] = date
    }

    func retryAt(accountID: String) -> Date? {
        retryDates[accountID]
    }
}

private struct OAuthUsageOutcome {
    let result: ProviderUsageResult?
    let permitsFallbackProbe: Bool
    let isSuccessfulSnapshot: Bool

    init(
        result: ProviderUsageResult?,
        permitsFallbackProbe: Bool,
        isSuccessfulSnapshot: Bool = false
    ) {
        self.result = result
        self.permitsFallbackProbe = permitsFallbackProbe
        self.isSuccessfulSnapshot = isSuccessfulSnapshot
    }
}

private struct TokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int64?
    let expiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
    }
}

private extension Date {
    var claudeUsageUnixTimeMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
