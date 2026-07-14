import Foundation

public final class CopilotUsageProvider: UsageProvider {
    private typealias GitHubTokenResolver = @Sendable (String) throws -> String?

    private static let editorVersion = "vscode/1.96.2"
    private static let editorPluginVersion = "copilot-chat/0.26.7"
    private static let userAgentProduct = "GitHubCopilotChat/0.26.7"
    private static let githubApiVersion = "2025-04-01"

    private let secretStore: any SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let gitHubTokenResolver: GitHubTokenResolver
    private let now: @Sendable () -> Date
    private let cliTokenCache = CopilotCLITokenCache()

    public let providerID = ProviderID.copilot

    public init(
        secretStore: any SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://api.github.com/copilot_internal/user")!,
        gitHubTokenResolver: (@Sendable (String) throws -> String?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.gitHubTokenResolver = gitHubTokenResolver ?? { username in
            try LocalCredentialDiscovery.gitHubAuthToken(for: username)
        }
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard configuration.copilotAccountScope == .personal else {
            return failureResult(
                "Organization Copilot usage is not yet supported on Mac.",
                configuration: configuration
            )
        }

        guard let resolved = resolveAccessToken(for: configuration) else {
            return failureResult(
                "Not configured - sign in with GitHub CLI or add a token.",
                configuration: configuration
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

    private enum ResolvedTokenSource {
        case keychain
        case cli(username: String)
    }

    private struct ResolvedAccessToken {
        let token: String
        let source: ResolvedTokenSource
    }

    private func resolveAccessToken(for configuration: ProviderAccountConfiguration) -> ResolvedAccessToken? {
        if configuration.authMethod == .cliToken,
           let cliToken = resolveCLIToken(for: configuration) {
            return cliToken
        }

        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        if let storedSecret = try? secretStore.readSecret(account: keychainAccount),
           let credentials = CopilotCredentialsParser.parse(storedSecret) {
            return ResolvedAccessToken(token: credentials.accessToken, source: .keychain)
        }

        return nil
    }

    private func resolveCLIToken(for configuration: ProviderAccountConfiguration) -> ResolvedAccessToken? {
        let username = configuration.githubCLIUsername
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackUsername = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedUsername = username.isEmpty ? fallbackUsername : username
        guard !resolvedUsername.isEmpty else {
            return nil
        }

        if let cached = cliTokenCache.token(for: resolvedUsername) {
            return ResolvedAccessToken(token: cached, source: .cli(username: resolvedUsername))
        }

        guard let token = try? gitHubTokenResolver(resolvedUsername)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }

        cliTokenCache.store(token, for: resolvedUsername)
        return ResolvedAccessToken(token: token, source: .cli(username: resolvedUsername))
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
            if case .cli(let username) = tokenSource {
                cliTokenCache.invalidate(username: username)
                guard let refreshed = resolveAccessToken(for: configuration) else {
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

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .copilot,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
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
            fetchedAt: result.fetchedAt
        )
    }
}

private final class CopilotCLITokenCache: @unchecked Sendable {
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