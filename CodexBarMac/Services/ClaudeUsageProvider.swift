import Foundation

public final class ClaudeUsageProvider: UsageProvider {
    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let tokenRefreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let refreshCoordinator = CredentialRefreshCoordinator<ClaudeCredentialRefreshResult>()

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
        try await fetchUsage(
            configuration: configuration,
            candidates: credentialCandidates(configuration: configuration)
        )
    }

    private func fetchUsage(
        configuration: ProviderAccountConfiguration,
        candidates: [LoadedCredentials]
    ) async throws -> ProviderUsageResult {
        guard var loaded = candidates.first else {
            return failureResult(
                notConfiguredMessage(for: configuration),
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }
        let fallbackCandidates = Array(candidates.dropFirst())

        if !credentialIsFresh(loaded.credentials),
           loaded.credentials.refreshToken?.isEmpty != false {
            return try await fallbackOrFailure(
                "Claude credential expired and cannot be renewed. Sign in again.",
                configuration: configuration,
                candidates: fallbackCandidates
            )
        }

        switch try await refreshedCredentialsIfNeeded(
            loaded.credentials,
            storage: loaded.storage,
            configuration: configuration
        ) {
        case .unchanged(let credentials), .refreshed(let credentials):
            loaded.credentials = credentials
        case .temporarilyUnavailable:
            return try await fallbackOrFailure(
                "Could not renew the Claude credential. Try again.",
                configuration: configuration,
                candidates: fallbackCandidates
            )
        case .rejected:
            return try await fallbackOrFailure(
                "Claude credential renewal was rejected. Sign in again.",
                configuration: configuration,
                candidates: fallbackCandidates
            )
        case .persistenceFailed:
            return try await fallbackOrFailure(
                "Could not securely save the renewed Claude credential. Sign in again.",
                configuration: configuration,
                candidates: fallbackCandidates
            )
        }
        guard var token = loaded.credentials.accessToken, !token.isEmpty else {
            return try await fallbackOrFailure(
                "Claude credential is missing an access token.",
                configuration: configuration,
                candidates: fallbackCandidates
            )
        }
        await snapshotCache.prepare(accountID: configuration.id, credential: token)

        let oauthOutcome = try await fetchOAuthUsage(
            configuration: configuration,
            loaded: &loaded,
            accessToken: &token,
            canRefresh: true
        )
        if oauthOutcome.shouldTryFallbackCredential, !fallbackCandidates.isEmpty {
            return try await fetchUsage(
                configuration: configuration,
                candidates: fallbackCandidates
            )
        }
        if let usageResult = oauthOutcome.result {
            if oauthOutcome.isSuccessfulSnapshot {
                return await snapshotCache.storePreservingBars(
                    usageResult,
                    accountID: configuration.id
                )
            }
            return usageResult
        }

        return await staleOrFailureResult(
            "Claude usage did not include rate-limit windows.",
            configuration: configuration
        )
    }

    private struct LoadedCredentials {
        var credentials: ClaudeCredentials
        let storage: ClaudeCredentialStore.Storage?
    }

    private func credentialCandidates(configuration: ProviderAccountConfiguration) -> [LoadedCredentials] {
        var candidates: [LoadedCredentials] = []
        if let local = ClaudeCredentialStore.readCredentials(
            keychainAccount: keychainAccount,
            credentialsFilePath: credentialsFilePath
        ) {
            candidates.append(LoadedCredentials(credentials: local.credentials, storage: local.storage))
        }

        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        if
            let storedSecret = try? secretStore.readSecret(account: account),
            let parsedCredentials = ClaudeCredentialsParser.parse(storedSecret),
            parsedCredentials.accessToken?.isEmpty == false
        {
            candidates.append(LoadedCredentials(credentials: parsedCredentials, storage: nil))
        }

        return candidates
    }

    private func notConfiguredMessage(for configuration: ProviderAccountConfiguration) -> String {
        switch configuration.authMethod {
        case .browserSession:
            "Not configured - sign in with Claude Code or Claude in the browser."
        default:
            "Not configured - sign in with Claude Code or Claude in the browser."
        }
    }

    private func fetchOAuthUsage(
        configuration: ProviderAccountConfiguration,
        loaded: inout LoadedCredentials,
        accessToken: inout String,
        canRefresh: Bool
    ) async throws -> OAuthUsageOutcome {
        let fetchedAt = now()
        if let retryAt = await snapshotCache.retryAt(accountID: configuration.id), retryAt > fetchedAt {
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude usage is rate-limited until \(Self.formatRetryDate(retryAt)).",
                    configuration: configuration
                )
            )
        }

        let (data, response) = try await session.data(for: makeOAuthUsageRequest(accessToken: accessToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            return OAuthUsageOutcome(
                result: failureResult("Claude usage returned an invalid response.", configuration: configuration)
            )
        }

        switch httpResponse.statusCode {
        case 200..<300:
            guard let parsed = ClaudeUsageParser.parse(
                data,
                subscriptionType: loaded.credentials.subscriptionType,
                fetchedAt: fetchedAt
            ) else {
                return OAuthUsageOutcome(result: nil)
            }
            let result = applyAccountMetadata(to: parsed, configuration: configuration)
            return OAuthUsageOutcome(
                result: result,
                isSuccessfulSnapshot: true
            )
        case 401 where canRefresh && loaded.credentials.refreshToken?.isEmpty == false:
            switch await refreshCredentials(
                loaded.credentials,
                storage: loaded.storage,
                configuration: configuration
            ) {
            case .refreshed(let refreshed), .unchanged(let refreshed):
                guard let newToken = refreshed.accessToken, !newToken.isEmpty else {
                    return OAuthUsageOutcome(
                        result: failureResult("Claude credential was rejected. Sign in again.", configuration: configuration),
                        shouldTryFallbackCredential: true
                    )
                }
                guard newToken != accessToken else {
                    return OAuthUsageOutcome(
                        result: failureResult("Claude credential was rejected. Sign in again.", configuration: configuration),
                        shouldTryFallbackCredential: true
                    )
                }
                loaded.credentials = refreshed
                accessToken = newToken
                await snapshotCache.adoptRotatedCredential(
                    accountID: configuration.id,
                    credential: newToken
                )
                return try await fetchOAuthUsage(
                    configuration: configuration,
                    loaded: &loaded,
                    accessToken: &accessToken,
                    canRefresh: false
                )
            case .rejected:
                return OAuthUsageOutcome(
                    result: failureResult("Claude credential renewal was rejected. Sign in again.", configuration: configuration),
                    shouldTryFallbackCredential: true
                )
            case .temporarilyUnavailable:
                return OAuthUsageOutcome(
                    result: failureResult("Could not renew the Claude credential. Try again.", configuration: configuration),
                    shouldTryFallbackCredential: true
                )
            case .persistenceFailed:
                return OAuthUsageOutcome(
                    result: failureResult("Could not securely save the renewed Claude credential. Sign in again.", configuration: configuration),
                    shouldTryFallbackCredential: true
                )
            case .unchanged:
                return OAuthUsageOutcome(
                    result: failureResult("Claude credential was rejected. Sign in again.", configuration: configuration),
                    shouldTryFallbackCredential: true
                )
            }
        case 401:
            return OAuthUsageOutcome(
                result: failureResult("Claude credential was rejected. Sign in again.", configuration: configuration),
                shouldTryFallbackCredential: true
            )
        case 403:
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude credential lacks permission to read subscription usage.",
                    configuration: configuration
                ),
                shouldTryFallbackCredential: true
            )
        case 404:
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude subscription usage is unavailable for this account.",
                    configuration: configuration
                )
            )
        case 429:
            let retryAt = retryDate(httpResponse, now: fetchedAt)
                ?? fetchedAt.addingTimeInterval(60)
            await snapshotCache.setRetryAt(retryAt, accountID: configuration.id)
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude usage is rate-limited until \(Self.formatRetryDate(retryAt)).",
                    configuration: configuration
                )
            )
        case 500..<600:
            return OAuthUsageOutcome(
                result: await staleOrFailureResult(
                    "Claude usage is temporarily unavailable (server error \(httpResponse.statusCode)).",
                    configuration: configuration
                )
            )
        default:
            return OAuthUsageOutcome(result: nil)
        }
    }

    private func refreshedCredentialsIfNeeded(
        _ credentials: ClaudeCredentials,
        storage: ClaudeCredentialStore.Storage?,
        configuration: ProviderAccountConfiguration
    ) async throws -> ClaudeCredentialRefreshResult {
        guard credentials.expiresAt > 0 else {
            return .unchanged(credentials)
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(normalizeEpochToSeconds(credentials.expiresAt)))
        guard expiresAt <= now() else {
            return .unchanged(credentials)
        }

        guard credentials.refreshToken?.isEmpty == false else {
            return .unchanged(credentials)
        }

        return await refreshCredentials(credentials, storage: storage, configuration: configuration)
    }

    private func refreshCredentials(
        _ credentials: ClaudeCredentials,
        storage: ClaudeCredentialStore.Storage?,
        configuration: ProviderAccountConfiguration
    ) async -> ClaudeCredentialRefreshResult {
        await Self.refreshCoordinator.run(for: refreshCoordinatorKey(storage: storage, configuration: configuration)) { [self] in
            await performCredentialRefresh(credentials, storage: storage, configuration: configuration)
        }
    }

    private func performCredentialRefresh(
        _ credentials: ClaudeCredentials,
        storage: ClaudeCredentialStore.Storage?,
        configuration: ProviderAccountConfiguration
    ) async -> ClaudeCredentialRefreshResult {
        if let latest = readLatestCredentials(storage: storage, configuration: configuration),
           latest != credentials {
            return .refreshed(latest)
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return .unchanged(credentials)
        }

        var request = URLRequest(url: Self.tokenRefreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try? JSONEncoder().encode([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return .temporarilyUnavailable
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return .temporarilyUnavailable
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if [400, 401, 403].contains(httpResponse.statusCode),
               let external = externallyRefreshedCredentials(
                original: credentials,
                storage: storage,
                configuration: configuration
            ) {
                return external
            }
            if [400, 401, 403].contains(httpResponse.statusCode) {
                return .rejected
            }
            return .temporarilyUnavailable
        }

        guard
            let refreshed = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data),
            let accessToken = refreshed.accessToken,
            !accessToken.isEmpty
        else {
            return .temporarilyUnavailable
        }

        let updated = ClaudeCredentials(
            subscriptionType: credentials.subscriptionType,
            rateLimitTier: credentials.rateLimitTier,
            expiresAt: refreshed.expiresAt ?? refreshed.expiresIn.map { now().addingTimeInterval(TimeInterval($0)).claudeUsageUnixTimeMilliseconds } ?? 0,
            accessToken: accessToken,
            refreshToken: refreshed.refreshToken ?? credentials.refreshToken
        )
        do {
            guard let latestCredentials = readLatestCredentials(
                storage: storage,
                configuration: configuration
            ) else {
                return .rejected
            }
            if latestCredentials != credentials {
                return .refreshed(latestCredentials)
            }
            try persistCredentials(updated, storage: storage, configuration: configuration)
        } catch {
            return .persistenceFailed
        }
        return .refreshed(updated)
    }

    private func externallyRefreshedCredentials(
        original: ClaudeCredentials,
        storage: ClaudeCredentialStore.Storage?,
        configuration: ProviderAccountConfiguration
    ) -> ClaudeCredentialRefreshResult? {
        guard
            let latest = readLatestCredentials(storage: storage, configuration: configuration),
            latest != original,
            credentialIsFresh(latest)
        else {
            return nil
        }

        return .refreshed(latest)
    }

    private func readLatestCredentials(
        storage: ClaudeCredentialStore.Storage?,
        configuration: ProviderAccountConfiguration
    ) -> ClaudeCredentials? {
        if let storage {
            return ClaudeCredentialStore.readCredentials(from: storage)
        }

        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard let secret = try? secretStore.readSecret(account: account) else {
            return nil
        }
        return ClaudeCredentialsParser.parse(secret)
    }

    private func credentialIsFresh(_ credentials: ClaudeCredentials) -> Bool {
        guard credentials.expiresAt > 0 else {
            return true
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(normalizeEpochToSeconds(credentials.expiresAt)))
        return expiresAt > now()
    }

    private func refreshCoordinatorKey(
        storage: ClaudeCredentialStore.Storage?,
        configuration: ProviderAccountConfiguration
    ) -> String {
        switch storage {
        case .keychain(let service, let account):
            "keychain:\(service):\(account)"
        case .file(let path):
            "file:\(path)"
        case nil:
            "settings:\(ProviderConfigurationStore.keychainAccount(for: configuration))"
        }
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

    private func failureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration,
        isIncompleteRefresh: Bool = true
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .claude,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            isIncompleteRefresh: isIncompleteRefresh,
            fetchedAt: Date()
        )
    }

    private func fallbackOrFailure(
        _ message: String,
        configuration: ProviderAccountConfiguration,
        candidates: [LoadedCredentials]
    ) async throws -> ProviderUsageResult {
        guard !candidates.isEmpty else {
            return failureResult(message, configuration: configuration)
        }
        return try await fetchUsage(configuration: configuration, candidates: candidates)
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
            monetaryMetrics: cached.monetaryMetrics,
            usageMessages: cached.usageMessages,
            hasReachedSpendLimit: cached.hasReachedSpendLimit,
            isIncompleteRefresh: true,
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
            monetaryMetrics: result.monetaryMetrics,
            usageMessages: result.usageMessages,
            hasReachedSpendLimit: result.hasReachedSpendLimit,
            isIncompleteRefresh: result.isIncompleteRefresh,
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

    func adoptRotatedCredential(accountID: String, credential: String) {
        credentials[accountID] = credential
    }

    func store(_ result: ProviderUsageResult, accountID: String) {
        results[accountID] = result
        retryDates[accountID] = nil
    }

    @discardableResult
    func storePreservingBars(_ result: ProviderUsageResult, accountID: String) -> ProviderUsageResult {
        guard result.bars.isEmpty else {
            store(result, accountID: accountID)
            return result
        }

        guard let cached = results[accountID], !cached.bars.isEmpty else {
            let partial = ProviderUsageResult(
                accountID: result.accountID,
                providerID: result.providerID,
                title: result.title,
                subtitle: result.subtitle,
                bars: result.bars,
                creditsRemaining: result.creditsRemaining,
                monetaryMetrics: result.monetaryMetrics,
                usageMessages: result.usageMessages,
                hasReachedSpendLimit: result.hasReachedSpendLimit,
                isIncompleteRefresh: true,
                fetchedAt: result.fetchedAt
            )
            store(partial, accountID: accountID)
            return partial
        }

        let preserved = ProviderUsageResult(
            accountID: result.accountID,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: cached.bars,
            creditsRemaining: result.creditsRemaining,
            monetaryMetrics: result.monetaryMetrics,
            usageMessages: result.usageMessages,
            hasReachedSpendLimit: result.hasReachedSpendLimit,
            // Cached quota bars are not part of this refresh's live payload.
            isIncompleteRefresh: true,
            fetchedAt: result.fetchedAt
        )
        results[accountID] = preserved
        retryDates[accountID] = nil
        return preserved
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

private enum ClaudeCredentialRefreshResult: Sendable {
    case unchanged(ClaudeCredentials)
    case refreshed(ClaudeCredentials)
    case rejected
    case temporarilyUnavailable
    case persistenceFailed
}

private struct OAuthUsageOutcome {
    let result: ProviderUsageResult?
    let isSuccessfulSnapshot: Bool
    let shouldTryFallbackCredential: Bool

    init(
        result: ProviderUsageResult?,
        isSuccessfulSnapshot: Bool = false,
        shouldTryFallbackCredential: Bool = false
    ) {
        self.result = result
        self.isSuccessfulSnapshot = isSuccessfulSnapshot
        self.shouldTryFallbackCredential = shouldTryFallbackCredential
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
