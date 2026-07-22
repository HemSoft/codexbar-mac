import Foundation

public final class CodexUsageProvider: UsageProvider {
    private static let refreshCoordinator = CredentialRefreshCoordinator<CredentialRefreshResult>()

    private let secretStore: any SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let tokenEndpoint: URL
    private let authFilePath: String
    private let now: @Sendable () -> Date

    public let providerID = ProviderID.codex

    public init(
        secretStore: any SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
        tokenEndpoint: URL = CodexTokenRefresh.tokenEndpoint,
        authFilePath: String = CodexAuthFileStore.defaultPath(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.authFilePath = authFilePath
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let location = credentialLocation(for: configuration)
        guard
            var credentials = try readCredentials(location: location)
        else {
            return failureResult(
                notConfiguredMessage(for: configuration),
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        var didRefresh = false
        if credentials.shouldRefresh(at: now()) {
            guard credentials.refreshToken?.isEmpty == false else {
                if credentials.isExpired(at: now()) {
                    return failureResult(
                        "ChatGPT / Codex credential expired and cannot be renewed. Sign in again.",
                        configuration: configuration
                    )
                }
                return try await fetchUsage(
                    configuration: configuration,
                    credentials: credentials,
                    location: location,
                    canRefresh: false
                )
            }

            switch await refreshCredentials(credentials, location: location) {
            case .success(let refreshed):
                credentials = refreshed
                didRefresh = true
            case .rejected:
                return failureResult(
                    "ChatGPT / Codex credential renewal was rejected. Sign in again.",
                    configuration: configuration
                )
            case .temporarilyUnavailable:
                if credentials.isExpired(at: now()) {
                    return failureResult(
                        "Could not renew the ChatGPT / Codex credential. Try again.",
                        configuration: configuration
                    )
                }
            case .persistenceFailed:
                return failureResult(
                    "Could not securely save the renewed ChatGPT / Codex credential. Sign in again.",
                    configuration: configuration
                )
            }
        }

        return try await fetchUsage(
            configuration: configuration,
            credentials: credentials,
            location: location,
            canRefresh: !didRefresh
        )
    }

    private func fetchUsage(
        configuration: ProviderAccountConfiguration,
        credentials: CodexCredentials,
        location: CredentialLocation,
        canRefresh: Bool
    ) async throws -> ProviderUsageResult {
        let (data, response) = try await session.data(for: makeUsageRequest(credentials: credentials))
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("ChatGPT usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return applyAccountMetadata(
                to: CodexUsageParser.parse(data, fetchedAt: now())
                    ?? failureResult("Could not parse ChatGPT usage.", configuration: configuration),
                configuration: configuration
            )
        case 401 where canRefresh && credentials.refreshToken?.isEmpty == false:
            switch await refreshCredentials(credentials, location: location) {
            case .success(let refreshed):
                return try await fetchUsage(
                    configuration: configuration,
                    credentials: refreshed,
                    location: location,
                    canRefresh: false
                )
            case .rejected:
                return failureResult(
                    "ChatGPT / Codex credential renewal was rejected. Sign in again.",
                    configuration: configuration
                )
            case .temporarilyUnavailable:
                return failureResult(
                    "Could not renew the ChatGPT / Codex credential. Try again.",
                    configuration: configuration
                )
            case .persistenceFailed:
                return failureResult(
                    "Could not securely save the renewed ChatGPT / Codex credential. Sign in again.",
                    configuration: configuration
                )
            }
        case 401:
            return failureResult(
                authenticationFailureMessage(for: credentials),
                configuration: configuration
            )
        case 403:
            return failureResult(
                "This ChatGPT account does not have access to Codex usage.",
                configuration: configuration
            )
        default:
            return failureResult("ChatGPT usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
        }
    }

    private func makeUsageRequest(credentials: CodexCredentials) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarMac", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    private func refreshCredentials(
        _ credentials: CodexCredentials,
        location: CredentialLocation
    ) async -> CredentialRefreshResult {
        await Self.refreshCoordinator.run(for: location.coordinatorKey) { [self] in
            await performCredentialRefresh(credentials, location: location)
        }
    }

    private func performCredentialRefresh(
        _ credentials: CodexCredentials,
        location: CredentialLocation
    ) async -> CredentialRefreshResult {
        do {
            guard let latestCredentials = try readCredentials(location: location) else {
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

        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CodexTokenRefresh.makeRefreshTokenRequestBody(refreshToken: refreshToken)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .temporarilyUnavailable
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                if [400, 401, 403].contains(httpResponse.statusCode),
                   let external = externallyRefreshedCredentials(original: credentials, location: location) {
                    return external
                }
                return [400, 401, 403].contains(httpResponse.statusCode) ? .rejected : .temporarilyUnavailable
            }
            guard let tokenResponse = try? JSONDecoder().decode(CodexTokenRefreshResponse.self, from: data) else {
                return .temporarilyUnavailable
            }
            if tokenResponse.error != nil {
                if let external = externallyRefreshedCredentials(original: credentials, location: location) {
                    return external
                }
                return .rejected
            }
            guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
                return .temporarilyUnavailable
            }

            let refreshedAt = now()
            let idToken = tokenResponse.idToken ?? credentials.idToken
            let parsedAccessToken = CodexCredentialsParser.parse(accessToken)
            let parsedIDToken = idToken.flatMap(CodexCredentialsParser.parse)
            let updated = CodexCredentials(
                accessToken: accessToken,
                refreshToken: tokenResponse.refreshToken ?? credentials.refreshToken,
                idToken: idToken,
                accountID: parsedIDToken?.accountID
                    ?? parsedAccessToken?.accountID
                    ?? credentials.accountID,
                expiresAt: tokenResponse.expiresAt.map(CodexCredentials.normalizedEpochSeconds)
                    ?? tokenResponse.expiresIn.map {
                        Int64(refreshedAt.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
                    }
                    ?? parsedAccessToken?.expiresAt
                    ?? parsedIDToken?.expiresAt
            )

            do {
                guard let latestCredentials = try readCredentials(location: location) else {
                    return .rejected
                }
                if latestCredentials != credentials {
                    return .success(latestCredentials)
                }
                try saveCredentials(updated, location: location)
            } catch {
                return .persistenceFailed
            }
            return .success(updated)
        } catch {
            return .temporarilyUnavailable
        }
    }

    private func externallyRefreshedCredentials(
        original: CodexCredentials,
        location: CredentialLocation
    ) -> CredentialRefreshResult? {
        guard
            let latest = try? readCredentials(location: location),
            latest != original,
            !latest.shouldRefresh(at: now())
        else {
            return nil
        }

        return .success(latest)
    }

    private func credentialLocation(for configuration: ProviderAccountConfiguration) -> CredentialLocation {
        switch configuration.authMethod {
        case .codexAuthJSON, .browserSession:
            return .authFile(
                authFilePath,
                keychainAccount: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
        default:
            return .keychain(ProviderConfigurationStore.keychainAccount(for: configuration))
        }
    }

    private func readCredentials(location: CredentialLocation) throws -> CodexCredentials? {
        switch location {
        case .authFile(let path, let keychainAccount):
            if let credentials = CodexAuthFileStore.readCredentials(at: path) {
                return credentials
            }
            guard let keychainAccount,
                  let secret = try secretStore.readSecret(account: keychainAccount) else {
                return nil
            }
            return CodexCredentialsParser.parse(secret)
        case .keychain(let account):
            guard let secret = try secretStore.readSecret(account: account) else {
                return nil
            }
            return CodexCredentialsParser.parse(secret)
        }
    }

    private func saveCredentials(_ credentials: CodexCredentials, location: CredentialLocation) throws {
        switch location {
        case .authFile(let path, let keychainAccount):
            if FileManager.default.fileExists(atPath: path) {
                try CodexAuthFileStore.writeCredentials(credentials, at: path)
            } else if let keychainAccount {
                try secretStore.saveSecret(
                    CodexCredentialsParser.storedCredential(from: credentials),
                    account: keychainAccount
                )
            }
        case .keychain(let account):
            try secretStore.saveSecret(
                CodexCredentialsParser.storedCredential(from: credentials),
                account: account
            )
        }
    }

    private func notConfiguredMessage(for configuration: ProviderAccountConfiguration) -> String {
        switch configuration.authMethod {
        case .codexAuthJSON:
            "Not configured - run Codex CLI or sign in with ChatGPT."
        case .browserSession:
            "Not configured - run Codex CLI or sign in with ChatGPT."
        default:
            "Not configured - sign in with ChatGPT."
        }
    }

    private func failureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration,
        isIncompleteRefresh: Bool = true
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            isIncompleteRefresh: isIncompleteRefresh,
            fetchedAt: now()
        )
    }

    private func authenticationFailureMessage(for credentials: CodexCredentials) -> String {
        if credentials.isExpired(at: now()) {
            return "ChatGPT / Codex credential expired. Sign in again."
        }
        if credentials.expiresAt != nil {
            return "ChatGPT / Codex authorization was revoked. Sign in again."
        }
        return "ChatGPT / Codex credential was rejected. Sign in again."
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

private enum CredentialLocation: Equatable {
    case authFile(String, keychainAccount: String?)
    case keychain(String)

    var coordinatorKey: String {
        switch self {
        case .authFile(let path, let keychainAccount):
            "auth-file:\(path)|keychain:\(keychainAccount ?? "")"
        case .keychain(let account):
            "keychain:\(account)"
        }
    }
}

private enum CredentialRefreshResult: Sendable {
    case success(CodexCredentials)
    case rejected
    case temporarilyUnavailable
    case persistenceFailed
}
