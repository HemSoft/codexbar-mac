import Foundation

public final class CopilotUsageProvider: UsageProvider {
    deinit {}

    private static let refreshCoordinator = CredentialRefreshCoordinator<CopilotCredentialRefreshResult>()
    private static let activeCLIAccountCacheKey = "__active__"
    private typealias GitHubTokenResolver = @Sendable (String?) throws -> String?

    private static let editorVersion = "vscode/1.96.2"
    private static let editorPluginVersion = "copilot-chat/0.26.7"
    private static let userAgentProduct = "GitHubCopilotChat/0.26.7"
    private static let githubApiVersion = "2025-04-01"
    private static let githubRestApiVersion = "2026-03-10"
    private static let githubRestUserAgent = "CodexBarMac/1.0"
    private static let promotionalCreditsPerSeat = 7_000
    private static let standardCreditsPerSeat = 3_900
    private static let promotionalBusinessCreditsPerSeat = 3_000
    private static let standardBusinessCreditsPerSeat = 1_900

    private let secretStore: any SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let githubAPIBaseURL: URL
    private let tokenEndpoint: URL
    private let oauthConfiguration: CopilotOAuthConfiguration
    private let gitHubTokenResolver: GitHubTokenResolver
    private let now: @Sendable () -> Date
    private let cliTokenCache = CopilotCLITokenCache()

    public let providerID = ProviderID.copilot

    public init(
        secretStore: any SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://api.github.com/copilot_internal/user")!,
        githubAPIBaseURL: URL = URL(string: "https://api.github.com")!,
        tokenEndpoint: URL = CopilotWebAuthService.tokenEndpoint,
        oauthConfiguration: CopilotOAuthConfiguration = .bundled,
        gitHubTokenResolver: (@Sendable (String?) throws -> String?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.githubAPIBaseURL = githubAPIBaseURL
        self.tokenEndpoint = tokenEndpoint
        self.oauthConfiguration = oauthConfiguration
        self.gitHubTokenResolver = gitHubTokenResolver ?? { username in
            try LocalCredentialDiscovery.gitHubAuthToken(for: username)
        }
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        if configuration.copilotAccountScope == .organization {
            let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
            if organization.isEmpty {
                return failureResult(
                    "Not configured - enter organization.",
                    configuration: configuration,
                    isIncompleteRefresh: false
                )
            }
        }

        guard let resolved = await resolveAccessToken(for: configuration) else {
            return failureResult(
                "Not configured - sign in with GitHub CLI or add a token.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        if configuration.copilotAccountScope == .organization {
            return try await fetchOrganizationUsage(
                configuration: configuration,
                accessToken: resolved.token,
                tokenSource: resolved.source,
                canRetryWithFreshCLIToken: true
            )
        }

        return try await fetchPersonalUsage(
            configuration: configuration,
            accessToken: resolved.token,
            tokenSource: resolved.source,
            canRetryWithFreshCLIToken: true
        )
    }

    func makeUsageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgentProduct, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.editorVersion, forHTTPHeaderField: "Editor-Version")
        request.setValue(Self.editorPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue(Self.githubApiVersion, forHTTPHeaderField: "X-Github-Api-Version")
        return request
    }

    public func fetchUsername(accessToken: String) async throws -> String? {
        let (data, response) = try await session.data(for: makeUsageRequest(accessToken: accessToken))
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            return nil
        }

        return CopilotUsageParser.username(from: data)
    }

    func makeOrganizationBillingRequest(
        accessToken: String,
        configuration: ProviderAccountConfiguration,
        date: Date = Date()
    ) -> URLRequest? {
        let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !organization.isEmpty else {
            return nil
        }

        let enterprise = configuration.githubEnterprise.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encodedOrganization = Self.pathEncodedComponent(organization) else {
            return nil
        }
        let dateComponents = Calendar.utcGregorian.dateComponents([.year, .month], from: date)
        guard let year = dateComponents.year, let month = dateComponents.month else {
            return nil
        }

        let path: String
        var queryItems = [
            URLQueryItem(name: "year", value: "\(year)"),
            URLQueryItem(name: "month", value: "\(month)"),
            URLQueryItem(name: "product", value: "Copilot"),
        ]

        if enterprise.isEmpty {
            path = "/organizations/\(encodedOrganization)/settings/billing/ai_credit/usage"
        } else {
            guard let encodedEnterprise = Self.pathEncodedComponent(enterprise) else {
                return nil
            }
            path = "/enterprises/\(encodedEnterprise)/settings/billing/ai_credit/usage"
            queryItems.append(URLQueryItem(name: "organization", value: organization))
        }

        var urlComponents = URLComponents(url: githubAPIBaseURL, resolvingAgainstBaseURL: false)
        urlComponents?.percentEncodedPath = path
        urlComponents?.queryItems = queryItems
        guard let url = urlComponents?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.githubRestApiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.githubRestUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    func makeOrganizationSeatCountRequest(
        accessToken: String,
        configuration: ProviderAccountConfiguration
    ) -> URLRequest? {
        let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !organization.isEmpty,
            let encodedOrganization = Self.pathEncodedComponent(organization)
        else {
            return nil
        }

        var urlComponents = URLComponents(url: githubAPIBaseURL, resolvingAgainstBaseURL: false)
        urlComponents?.percentEncodedPath = "/orgs/\(encodedOrganization)/copilot/billing"
        guard let url = urlComponents?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.githubRestApiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.githubRestUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func creditsPerSeat(year: Int, month: Int, planType: String? = nil) -> Int {
        let isPromotionalWindow = year == 2026 && (6...8).contains(month)
        let normalizedPlan = planType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let isBusinessPlan = normalizedPlan.contains("business")
        if isBusinessPlan {
            return isPromotionalWindow
                ? promotionalBusinessCreditsPerSeat
                : standardBusinessCreditsPerSeat
        }
        return isPromotionalWindow
            ? promotionalCreditsPerSeat
            : standardCreditsPerSeat
    }

    private enum ResolvedTokenSource {
        case keychain(CopilotCredentials)
        case cli(username: String)
    }

    private struct ResolvedAccessToken {
        let token: String
        let source: ResolvedTokenSource
    }

    private func resolveAccessToken(for configuration: ProviderAccountConfiguration) async -> ResolvedAccessToken? {
        if configuration.authMethod == .cliToken {
            let cliUsername = configuration.githubCLIUsername
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let prefersCLI = !cliUsername.isEmpty

            if prefersCLI, let cliToken = await resolveCLIToken(for: configuration) {
                return cliToken
            }

            if let keychainToken = await resolveKeychainToken(for: configuration) {
                return keychainToken
            }

            if !prefersCLI, let cliToken = await resolveCLIToken(for: configuration) {
                return cliToken
            }

            return nil
        }

        let cliUsername = configuration.githubCLIUsername
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cliUsername.isEmpty, let cliToken = await resolveCLIToken(for: configuration) {
            return cliToken
        }
        return await resolveKeychainToken(for: configuration)
    }

    private func resolveKeychainToken(for configuration: ProviderAccountConfiguration) async -> ResolvedAccessToken? {
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard
            let storedSecret = try? secretStore.readSecret(account: keychainAccount),
            var credentials = CopilotCredentialsParser.parse(storedSecret)
        else {
            return nil
        }

        if credentials.shouldRefresh(at: now()), credentials.refreshToken?.isEmpty == false {
            switch await refreshCredentials(credentials, keychainAccount: keychainAccount) {
            case .success(let refreshed):
                credentials = refreshed
            case .temporarilyUnavailable where !credentials.isExpired(at: now()):
                break
            case .expired, .rejected, .temporarilyUnavailable, .persistenceFailed:
                return nil
            }
        } else if credentials.isExpired(at: now()) {
            return nil
        }

        return ResolvedAccessToken(token: credentials.accessToken, source: .keychain(credentials))
    }

    private func resolveCLIToken(for configuration: ProviderAccountConfiguration) async -> ResolvedAccessToken? {
        let explicitUsername = configuration.githubCLIUsername
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = explicitUsername.isEmpty ? Self.activeCLIAccountCacheKey : explicitUsername
        let resolverUsername: String? = explicitUsername.isEmpty ? nil : explicitUsername

        if !explicitUsername.isEmpty, let cached = cliTokenCache.token(for: cacheKey) {
            return ResolvedAccessToken(token: cached, source: .cli(username: cacheKey))
        }

        let resolver = gitHubTokenResolver
        let token = await Task.detached(priority: .utility) {
            try? resolver(resolverUsername)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        guard let token, !token.isEmpty else {
            return nil
        }

        if !explicitUsername.isEmpty {
            cliTokenCache.store(token, for: cacheKey)
        }
        return ResolvedAccessToken(token: token, source: .cli(username: cacheKey))
    }

    private func fetchPersonalUsage(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        tokenSource: ResolvedTokenSource,
        canRetryWithFreshCLIToken: Bool
    ) async throws -> ProviderUsageResult {
        let (data, response) = try await session.data(for: makeUsageRequest(accessToken: accessToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("GitHub Copilot usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return applyAccountMetadata(
                to: CopilotUsageParser.parse(data, fetchedAt: now())
                    ?? failureResult("Could not parse GitHub Copilot usage.", configuration: configuration),
                configuration: configuration
            )
        case 401 where canRetryWithFreshCLIToken:
            return try await retryAfterCredentialRefresh(
                configuration: configuration,
                accessToken: accessToken,
                tokenSource: tokenSource
            ) { configuration, token, source in
                try await self.fetchPersonalUsage(
                    configuration: configuration,
                    accessToken: token,
                    tokenSource: source,
                    canRetryWithFreshCLIToken: false
                )
            }
        case 401:
            return failureResult("GitHub credential was rejected. Sign in again.", configuration: configuration)
        case 403 where Self.isRateLimited(httpResponse):
            return failureResult("GitHub rate limit reached. Try again later.", configuration: configuration)
        case 403:
            return failureResult("This GitHub account does not have access to Copilot usage.", configuration: configuration)
        default:
            return failureResult("GitHub Copilot usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
        }
    }

    private func fetchOrganizationUsage(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        tokenSource: ResolvedTokenSource,
        canRetryWithFreshCLIToken: Bool
    ) async throws -> ProviderUsageResult {
        guard let request = makeOrganizationBillingRequest(
            accessToken: accessToken,
            configuration: configuration,
            date: now()
        ) else {
            return failureResult(
                "Not configured - enter organization.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult(
                "GitHub Copilot organization usage returned an invalid response.",
                configuration: configuration
            )
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let effectiveAllotment = await resolveOrganizationAllotment(
                configuration: configuration,
                accessToken: accessToken,
                date: now()
            )
            return applyAccountMetadata(
                to: CopilotBillingUsageParser.parse(
                    data,
                    configuration: configuration,
                    fetchedAt: now(),
                    totalAllotment: effectiveAllotment
                ) ?? failureResult(
                    "Could not parse GitHub Copilot organization usage.",
                    configuration: configuration
                ),
                configuration: configuration
            )
        case 401 where canRetryWithFreshCLIToken:
            return try await retryAfterCredentialRefresh(
                configuration: configuration,
                accessToken: accessToken,
                tokenSource: tokenSource
            ) { configuration, token, source in
                try await self.fetchOrganizationUsage(
                    configuration: configuration,
                    accessToken: token,
                    tokenSource: source,
                    canRetryWithFreshCLIToken: false
                )
            }
        case 401:
            return failureResult("GitHub credential was rejected. Sign in again.", configuration: configuration)
        case 403 where Self.isRateLimited(httpResponse):
            return failureResult("GitHub rate limit reached. Try again later.", configuration: configuration)
        case 403:
            return failureResult(
                "This GitHub account lacks permission to read the configured Copilot organization billing data.",
                configuration: configuration
            )
        case 404:
            return failureResult(
                "GitHub Copilot organization not found. Check the configured organization name.",
                configuration: configuration
            )
        default:
            return failureResult(
                "GitHub Copilot organization usage returned HTTP \(httpResponse.statusCode).",
                configuration: configuration
            )
        }
    }

    private func retryAfterCredentialRefresh(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        tokenSource: ResolvedTokenSource,
        retry: (ProviderAccountConfiguration, String, ResolvedTokenSource) async throws -> ProviderUsageResult
    ) async throws -> ProviderUsageResult {
        let refreshed: ResolvedAccessToken?
        switch tokenSource {
        case .cli(let username):
            cliTokenCache.invalidate(username: username)
            refreshed = await resolveAccessToken(for: configuration)
        case .keychain(let credentials):
            let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
            switch await refreshCredentials(credentials, keychainAccount: keychainAccount) {
            case .success(let updated):
                refreshed = ResolvedAccessToken(token: updated.accessToken, source: .keychain(updated))
            case .expired, .rejected, .temporarilyUnavailable, .persistenceFailed:
                refreshed = nil
            }
        }

        guard let refreshed, refreshed.token != accessToken else {
            return failureResult(authenticationFailureMessage(for: tokenSource), configuration: configuration)
        }
        return try await retry(configuration, refreshed.token, refreshed.source)
    }

    private func refreshCredentials(
        _ credentials: CopilotCredentials,
        keychainAccount: String
    ) async -> CopilotCredentialRefreshResult {
        await Self.refreshCoordinator.run(for: keychainAccount) { [self] in
            await performCredentialRefresh(credentials, keychainAccount: keychainAccount)
        }
    }

    private func performCredentialRefresh(
        _ credentials: CopilotCredentials,
        keychainAccount: String
    ) async -> CopilotCredentialRefreshResult {
        do {
            guard
                let storedSecret = try secretStore.readSecret(account: keychainAccount),
                let latestCredentials = CopilotCredentialsParser.parse(storedSecret)
            else {
                return .rejected
            }
            if latestCredentials != credentials {
                return .success(latestCredentials)
            }
        } catch {
            return .temporarilyUnavailable
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return .rejected
        }
        if let refreshTokenExpiresAt = credentials.refreshTokenExpiresAt,
           Date(timeIntervalSince1970: TimeInterval(refreshTokenExpiresAt)) <= now() {
            return .expired
        }

        let clientID = oauthConfiguration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = oauthConfiguration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            return .temporarilyUnavailable
        }

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CopilotWebAuthService.makeRefreshTokenRequestBody(
            clientID: clientID,
            clientSecret: clientSecret,
            refreshToken: refreshToken
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .temporarilyUnavailable
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                return [400, 401, 403].contains(httpResponse.statusCode) ? .rejected : .temporarilyUnavailable
            }
            guard let tokenResponse = try? JSONDecoder().decode(CopilotTokenRefreshResponse.self, from: data) else {
                return .temporarilyUnavailable
            }
            if tokenResponse.error != nil {
                return .rejected
            }
            guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
                return .temporarilyUnavailable
            }

            let refreshedAt = now()
            let updated = CopilotCredentials(
                accessToken: accessToken,
                username: credentials.username,
                refreshToken: tokenResponse.refreshToken ?? credentials.refreshToken,
                expiresAt: tokenResponse.expiresIn.map {
                    Int64(refreshedAt.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
                },
                refreshTokenExpiresAt: tokenResponse.refreshTokenExpiresIn.map {
                    Int64(refreshedAt.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
                } ?? (tokenResponse.refreshToken == nil ? credentials.refreshTokenExpiresAt : nil)
            )

            do {
                guard
                    let storedSecret = try secretStore.readSecret(account: keychainAccount),
                    let latestCredentials = CopilotCredentialsParser.parse(storedSecret)
                else {
                    return .rejected
                }
                if latestCredentials != credentials {
                    return .success(latestCredentials)
                }
                try secretStore.saveSecret(
                    CopilotCredentialsParser.storedCredential(from: updated),
                    account: keychainAccount
                )
            } catch {
                return .persistenceFailed
            }
            return .success(updated)
        } catch {
            return .temporarilyUnavailable
        }
    }

    private func authenticationFailureMessage(for tokenSource: ResolvedTokenSource) -> String {
        guard case .keychain(let credentials) = tokenSource else {
            return "GitHub credential was rejected. Sign in again."
        }
        if credentials.isExpired(at: now()) {
            return "GitHub credential expired. Sign in again."
        }
        if credentials.expiresAt != nil {
            return "GitHub authorization was revoked. Sign in again."
        }
        return "GitHub credential was rejected. Sign in again."
    }

    private func resolveOrganizationAllotment(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        date: Date = Date()
    ) async -> Double? {
        if let override = configuration.copilotTotalAllotment, override > 0 {
            return override
        }

        guard let request = makeOrganizationSeatCountRequest(accessToken: accessToken, configuration: configuration) else {
            return nil
        }

        guard let (data, response) = try? await session.data(for: request) else {
            return nil
        }
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let seatInfo = CopilotSeatCountParser.parse(data),
            seatInfo.totalSeats > 0
        else {
            return nil
        }

        let components = Calendar.utcGregorian.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            return nil
        }

        return Double(
            seatInfo.totalSeats * Self.creditsPerSeat(
                year: year,
                month: month,
                planType: seatInfo.planType
            )
        )
    }

    private static func pathEncodedComponent(_ value: String) -> String? {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    private func failureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration,
        isIncompleteRefresh: Bool = true
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .copilot,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            isIncompleteRefresh: isIncompleteRefresh,
            fetchedAt: now()
        )
    }

    private static func isRateLimited(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Retry-After") != nil
            || response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
    }

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
}

private enum CopilotCredentialRefreshResult: Sendable {
    case success(CopilotCredentials)
    case expired
    case rejected
    case temporarilyUnavailable
    case persistenceFailed
}

private struct CopilotTokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int64?
    let refreshTokenExpiresIn: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case error
    }
}

private final class CopilotCLITokenCache: @unchecked Sendable {
    deinit {}

    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func token(for username: String) -> String? {
        lock.withLock {
            tokens[username.lowercased()]
        }
    }

    func store(_ token: String, for username: String) {
        lock.withLock {
            tokens[username.lowercased()] = token
        }
    }

    func invalidate(username: String) {
        lock.withLock {
            tokens.removeValue(forKey: username.lowercased())
        }
    }
}
