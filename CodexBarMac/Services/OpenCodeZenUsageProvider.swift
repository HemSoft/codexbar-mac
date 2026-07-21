import Foundation

public final class OpenCodeZenUsageProvider: UsageProvider {
    private let secretStore: any SecretStore
    private let session: URLSession
    private let dashboardBaseURL: URL

    public let providerID = ProviderID.openCodeZen

    public init(
        secretStore: any SecretStore = KeychainService(),
        session: URLSession = .shared,
        dashboardBaseURL: URL = URL(string: "https://opencode.ai")!
    ) {
        self.secretStore = secretStore
        self.session = session
        self.dashboardBaseURL = dashboardBaseURL
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))
        guard let workspaceId = Self.normalizedWorkspaceId(from: configuration.openCodeWorkspaceId)
            ?? Self.workspaceId(fromCredentialPayload: storedSecret)
        else {
            return failureResult(
                "Not configured - enter OpenCode workspace ID.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        guard let balanceCredential = Self.normalizedAPIKey(from: storedSecret) else {
            return failureResult(
                "Not configured - enter OpenCode dashboard auth value.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        return await fetchDashboard(
            workspaceId: workspaceId,
            apiKey: balanceCredential,
            configuration: configuration
        )
    }

    func makeDashboardRequest(workspaceId: String, apiKey: String) -> URLRequest {
        var url = dashboardBaseURL
        url.append(path: "workspace")
        url.append(path: workspaceId)
        url.append(path: "billing")

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("auth=\(apiKey)", forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/148.0",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private func fetchDashboard(
        workspaceId: String,
        apiKey: String,
        configuration: ProviderAccountConfiguration
    ) async -> ProviderUsageResult {
        do {
            let (data, response) = try await session.data(for: makeDashboardRequest(workspaceId: workspaceId, apiKey: apiKey))
            guard let httpResponse = response as? HTTPURLResponse else {
                return failureResult("OpenCode ZEN balance returned an invalid response.", configuration: configuration)
            }

            switch httpResponse.statusCode {
            case 200..<300:
                if let text = String(data: data, encoding: .utf8), Self.looksLikeOpenAuthPage(text) {
                    let message = Self.looksLikeZenModelAPIKey(apiKey)
                        ? "OpenCode ZEN API keys are valid for models, but OpenCode does not expose balance to API keys."
                        : "OpenCode returned the sign-in page. Refresh the saved dashboard auth value."
                    return failureResult(message, configuration: configuration)
                }

                return Self.parseBalance(data, configuration: configuration)
                    ?? failureResult("Could not parse OpenCode ZEN balance.", configuration: configuration)
            case 401, 403:
                return failureResult("OpenCode ZEN rejected this dashboard authentication.", configuration: configuration)
            case 429:
                return failureResult("OpenCode ZEN rate limit reached. Try again later.", configuration: configuration)
            default:
                return failureResult("OpenCode ZEN dashboard returned HTTP \(httpResponse.statusCode).", configuration: configuration)
            }
        } catch {
            return failureResult(error.localizedDescription, configuration: configuration)
        }
    }

    static func parseBalance(
        _ data: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        if let jsonBalance = parseJSONBalance(data) {
            return buildResult(balance: jsonBalance, configuration: configuration, fetchedAt: fetchedAt)
        }

        if
            let text = String(data: data, encoding: .utf8),
            let dashboardBalance = parseDashboardBalance(text)
        {
            return buildResult(balance: dashboardBalance, configuration: configuration, fetchedAt: fetchedAt)
        }

        return nil
    }

    static func normalizedBalanceCredential(from storedSecret: String?) -> String? {
        normalizedAPIKey(from: storedSecret)
    }

    static func normalizedAPIKey(from storedSecret: String?) -> String? {
        guard var credential = storedSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            return nil
        }

        if let settingsCredential = openCodeDashboardCredential(fromSettingsJSON: credential)
            ?? environmentValue(named: "OPENCODE_ZEN_AUTH_COOKIE", in: credential)
            ?? environmentValue(named: "OPENCODE_GO_AUTH_COOKIE", in: credential)
        {
            credential = settingsCredential
        }

        guard var credential = CredentialNormalizer.normalizedBearerKey(from: credential) else {
            return nil
        }

        let cookiePrefix = "cookie:"
        if credential.lowercased().hasPrefix(cookiePrefix) {
            credential = String(credential.dropFirst(cookiePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let setCookiePrefix = "set-cookie:"
        if credential.lowercased().hasPrefix(setCookiePrefix) {
            credential = String(credential.dropFirst(setCookiePrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if
            let authValue = cookieValue(named: "auth", from: credential),
            !authValue.isEmpty
        {
            credential = authValue
        }

        return credential.isEmpty ? nil : credential
    }

    static func normalizedWorkspaceId(from value: String?) -> String? {
        var workspaceId = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let settingsWorkspaceId = openCodeWorkspaceId(fromSettingsJSON: workspaceId)
            ?? environmentValue(named: "OPENCODE_ZEN_WORKSPACE_ID", in: workspaceId)
            ?? environmentValue(named: "OPENCODE_GO_WORKSPACE_ID", in: workspaceId)
        {
            workspaceId = settingsWorkspaceId
        }

        if
            let url = URL(string: workspaceId),
            let workspaceIndex = url.pathComponents.firstIndex(of: "workspace"),
            url.pathComponents.indices.contains(workspaceIndex + 1)
        {
            workspaceId = url.pathComponents[workspaceIndex + 1]
        }

        workspaceId = workspaceId
            .replacingOccurrences(of: "/billing", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        return workspaceId.isEmpty ? nil : workspaceId
    }

    private static func workspaceId(fromCredentialPayload value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workspaceId = openCodeWorkspaceId(fromSettingsJSON: trimmed)
            ?? environmentValue(named: "OPENCODE_ZEN_WORKSPACE_ID", in: trimmed)
            ?? environmentValue(named: "OPENCODE_GO_WORKSPACE_ID", in: trimmed)
        {
            return normalizedWorkspaceId(from: workspaceId)
        }

        if
            let url = URL(string: trimmed),
            let workspaceIndex = url.pathComponents.firstIndex(of: "workspace"),
            url.pathComponents.indices.contains(workspaceIndex + 1)
        {
            return normalizedWorkspaceId(from: trimmed)
        }

        return nil
    }

    private static func parseJSONBalance(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let payload = root as? [String: Any] {
            return balance(from: payload)
                ?? (payload["data"] as? [String: Any]).flatMap { balance(from: $0) }
                ?? (payload["credits"] as? [String: Any]).flatMap { balance(from: $0) }
        }

        return nil
    }

    private static func balance(from payload: [String: Any]) -> Double? {
        for key in ["balance", "current_balance", "currentBalance", "credits_remaining", "creditsRemaining"] {
            if let value = number(from: payload[key]) {
                return value
            }
        }

        return nil
    }

    private static func parseDashboardBalance(_ text: String) -> Double? {
        for pattern in [
            #"balance\s*:\s*(\d+)"#,
            #""balance"\s*:\s*(\d+)"#,
            #"\\?"balance\\?"\s*:\s*(\d+)"#,
        ] {
            guard let range = text.range(of: pattern, options: .regularExpression) else {
                continue
            }

            let match = String(text[range])
            guard
                let digitsRange = match.range(of: #"\d+"#, options: .regularExpression),
                let rawBalance = Double(match[digitsRange])
            else {
                continue
            }

            return rawBalance / 100_000_000
        }

        return nil
    }

    private static func looksLikeOpenAuthPage(_ text: String) -> Bool {
        ["<title>OpenAuth</title>", "openauth.js.org", "OpenAuth"].contains { marker in
            text.range(of: marker, options: .caseInsensitive) != nil
        }
    }

    static func looksLikeZenModelAPIKey(_ credential: String) -> Bool {
        credential.hasPrefix("sk-")
    }

    private static func openCodeDashboardCredential(fromSettingsJSON value: String) -> String? {
        guard let root = jsonObject(from: value) else {
            return nil
        }

        let providers = root["providers"] as? [String: Any]
        if let goCredential = providerAPIKey(named: "OpenCodeGo", in: providers) {
            return goCredential
        }

        if
            let zenCredential = providerAPIKey(named: "OpenCodeZen", in: providers),
            !looksLikeZenModelAPIKey(zenCredential)
        {
            return zenCredential
        }

        return nil
    }

    private static func openCodeWorkspaceId(fromSettingsJSON value: String) -> String? {
        guard let root = jsonObject(from: value) else {
            return nil
        }

        return nonEmptyString(root["openCodeGoWorkspaceId"])
    }

    private static func providerAPIKey(named providerName: String, in providers: [String: Any]?) -> String? {
        guard let provider = providers?[providerName] as? [String: Any] else {
            return nil
        }

        return nonEmptyString(provider["apiKey"])
    }

    private static func jsonObject(from value: String) -> [String: Any]? {
        guard
            let data = value.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return root
    }

    private static func environmentValue(named name: String, in value: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?i)(?:^|[\s;])"# + escapedName + #"\s*=\s*("[^"]+"|'[^']+'|[^\s;]+)"#
        let fullRange = NSRange(location: 0, length: value.utf16.count)
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: value, range: fullRange),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }

        return unquote(String(value[captureRange]))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unquote(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if
            result.count >= 2,
            let first = result.first,
            let last = result.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            result.removeFirst()
            result.removeLast()
        }

        return result
    }

    private static func cookieValue(named name: String, from header: String) -> String? {
        let parts = header.split(separator: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("\(name.lowercased())=") else {
                continue
            }

            return String(trimmed.dropFirst(name.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func buildResult(
        balance: Double,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: balance,
            fetchedAt: fetchedAt
        )
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
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
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            isIncompleteRefresh: isIncompleteRefresh,
            fetchedAt: Date()
        )
    }
}
