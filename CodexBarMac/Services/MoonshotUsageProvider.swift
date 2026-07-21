import Foundation

public final class MoonshotUsageProvider: UsageProvider {
    deinit {}

    private let secretStore: any SecretStore
    private let session: URLSession
    private let balanceEndpoint: URL
    private let now: @Sendable () -> Date

    public let providerID = ProviderID.moonshot

    // Balance endpoint for API keys created on platform.kimi.ai. Keys from
    // platform.kimi.com are independent and will not authenticate here.
    public init(
        secretStore: any SecretStore = KeychainService(),
        session: URLSession = .shared,
        balanceEndpoint: URL = URL(string: "https://api.moonshot.ai/v1/users/me/balance")!,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.balanceEndpoint = balanceEndpoint
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            let apiKey = Self.normalizedAPIKey(from: storedSecret),
            !apiKey.isEmpty
        else {
            return failureResult(
                "Not configured - enter API key.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        do {
            let (data, response) = try await session.data(for: makeBalanceRequest(apiKey: apiKey))
            guard let httpResponse = response as? HTTPURLResponse else {
                return failureResult("Moonshot balance returned an invalid response.", configuration: configuration)
            }

            switch httpResponse.statusCode {
            case 200..<300:
                return Self.parseBalance(data, configuration: configuration, fetchedAt: now())
                    ?? failureResult("Could not parse Moonshot balance.", configuration: configuration)
            case 401, 403:
                return failureResult("Moonshot rejected this API key.", configuration: configuration)
            case 429:
                return failureResult("Moonshot rate limit reached. Try again later.", configuration: configuration)
            default:
                return failureResult("Moonshot balance returned HTTP \(httpResponse.statusCode).", configuration: configuration)
            }
        } catch {
            return failureResult(error.localizedDescription, configuration: configuration)
        }
    }

    func makeBalanceRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: balanceEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarMac/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func parseBalance(
        _ data: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = root["data"] as? [String: Any],
            let availableBalance = number(from: payload["available_balance"])
        else {
            return nil
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .moonshot,
            title: configuration.displayName,
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: availableBalance,
            fetchedAt: fetchedAt
        )
    }

    static func normalizedAPIKey(from storedSecret: String?) -> String? {
        guard var key = storedSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }

        if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 {
            key.removeFirst()
            key.removeLast()
        }

        let authorizationPrefix = "authorization:"
        if key.lowercased().hasPrefix(authorizationPrefix) {
            key = String(key.dropFirst(authorizationPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bearerPrefix = "bearer "
        if key.lowercased().hasPrefix(bearerPrefix) {
            key = String(key.dropFirst(bearerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return key.isEmpty ? nil : key
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string)
        default:
            nil
        }
    }

    private func failureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration,
        isIncompleteRefresh: Bool = true
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .moonshot,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            isIncompleteRefresh: isIncompleteRefresh,
            fetchedAt: now()
        )
    }
}
