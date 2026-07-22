import Foundation

public final class CopilotUsageProvider: UsageProvider {
    deinit {}

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
    private let gitHubTokenResolver: GitHubTokenResolver
    private let now: @Sendable () -> Date
    private let cliTokenCache = CopilotCLITokenCache()

    public let providerID = ProviderID.copilot

    public init(
        secretStore: any SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://api.github.com/copilot_internal/user")!,
        githubAPIBaseURL: URL = URL(string: "https://api.github.com")!,
        gitHubTokenResolver: (@Sendable (String?) throws -> String?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.githubAPIBaseURL = githubAPIBaseURL
        self.gitHubTokenResolver = gitHubTokenResolver ?? { username in
            try LocalCredentialDiscovery.gitHubAuthToken(for: username)
        }
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
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
        guard let encodedOrganization = organization.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        let calendar = Calendar(identifier: .gregorian)
        let dateComponents = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
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
            guard let encodedEnterprise = enterprise.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
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
            let encodedOrganization = organization.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
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
        case keychain
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

            if let keychainToken = resolveKeychainToken(for: configuration) {
                return keychainToken
            }

            if !prefersCLI, let cliToken = await resolveCLIToken(for: configuration) {
                return cliToken
            }

            return nil
        }

        return resolveKeychainToken(for: configuration)
    }

    private func resolveKeychainToken(for configuration: ProviderAccountConfiguration) -> ResolvedAccessToken? {
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        if let storedSecret = try? secretStore.readSecret(account: keychainAccount),
           let credentials = CopilotCredentialsParser.parse(storedSecret) {
            return ResolvedAccessToken(token: credentials.accessToken, source: .keychain)
        }

        return nil
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
            return try await retryPersonalAfterCLIRefresh(
                configuration: configuration,
                accessToken: accessToken,
                tokenSource: tokenSource
            )
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
            let effectiveAllotment = try await resolveOrganizationAllotment(
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
            return try await retryOrganizationAfterCLIRefresh(
                configuration: configuration,
                accessToken: accessToken,
                tokenSource: tokenSource
            )
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

    private func retryPersonalAfterCLIRefresh(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        tokenSource: ResolvedTokenSource
    ) async throws -> ProviderUsageResult {
        if case .cli(let username) = tokenSource {
            cliTokenCache.invalidate(username: username)
            guard let refreshed = await resolveAccessToken(for: configuration) else {
                return failureResult("GitHub credential was rejected. Sign in again.", configuration: configuration)
            }
            guard refreshed.token != accessToken else {
                return failureResult("GitHub credential was rejected. Sign in again.", configuration: configuration)
            }
            return try await fetchPersonalUsage(
                configuration: configuration,
                accessToken: refreshed.token,
                tokenSource: refreshed.source,
                canRetryWithFreshCLIToken: false
            )
        }
        return failureResult("GitHub credential was rejected. Sign in again.", configuration: configuration)
    }

    private func retryOrganizationAfterCLIRefresh(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        tokenSource: ResolvedTokenSource
    ) async throws -> ProviderUsageResult {
        if case .cli(let username) = tokenSource {
            cliTokenCache.invalidate(username: username)
            guard let refreshed = await resolveAccessToken(for: configuration) else {
                return failureResult("GitHub credential was rejected. Sign in again.", configuration: configuration)
            }
            guard refreshed.token != accessToken else {
                return failureResult("GitHub credential was rejected. Sign in again.", configuration: configuration)
            }
            return try await fetchOrganizationUsage(
                configuration: configuration,
                accessToken: refreshed.token,
                tokenSource: refreshed.source,
                canRetryWithFreshCLIToken: false
            )
        }
        return failureResult("GitHub credential was rejected. Sign in again.", configuration: configuration)
    }

    private func resolveOrganizationAllotment(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        date: Date = Date()
    ) async throws -> Double? {
        if let override = configuration.copilotTotalAllotment, override > 0 {
            return override
        }

        guard let request = makeOrganizationSeatCountRequest(accessToken: accessToken, configuration: configuration) else {
            return nil
        }

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let seatInfo = CopilotSeatCountParser.parse(data),
            seatInfo.totalSeats > 0
        else {
            return nil
        }

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
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
