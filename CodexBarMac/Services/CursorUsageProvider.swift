import Foundation

public final class CursorUsageProvider: UsageProvider {
    private let secretStore: any SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let authFilePath: String

    public let providerID = ProviderID.cursor

    public init(
        secretStore: any SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!,
        authFilePath: String = CursorCredentialsParser.defaultAuthPath()
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.authFilePath = authFilePath
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard let accessToken = try resolveAccessToken(for: configuration) else {
            return failureResult("Not configured - sign in with Cursor.", configuration: configuration)
        }

        do {
            let (data, response) = try await session.data(for: makeUsageRequest(accessToken: accessToken))
            guard let httpResponse = response as? HTTPURLResponse else {
                return failureResult("Cursor usage returned an invalid response.", configuration: configuration)
            }

            switch httpResponse.statusCode {
            case 200..<300:
                return Self.parseUsage(data, configuration: configuration)
                    ?? failureResult("Could not parse Cursor usage.", configuration: configuration)
            case 401, 403:
                return failureResult("Cursor rejected this session token. Sign in again.", configuration: configuration)
            case 429:
                return failureResult("Cursor rate limit reached. Try again later.", configuration: configuration)
            default:
                return failureResult("Cursor usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
            }
        } catch {
            return failureResult(error.localizedDescription, configuration: configuration)
        }
    }

    func makeUsageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("CodexBarMac/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func parseUsage(
        _ data: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        guard let usage = try? JSONDecoder().decode(CursorCurrentPeriodUsage.self, from: data) else {
            return nil
        }

        let bars = buildUsageBars(usage, fetchedAt: fetchedAt)
        guard !bars.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: configuration.displayName,
            subtitle: buildUsageSubtitle(usage.planUsage),
            bars: bars,
            hasReachedSpendLimit: hasReachedSpendLimit(usage),
            fetchedAt: fetchedAt
        )
    }

    static func normalizedAccessToken(from storedSecret: String?) -> String? {
        guard var token = storedSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
            token.removeFirst()
            token.removeLast()
        }

        if let data = token.data(using: .utf8),
           let credentials = try? JSONDecoder().decode(CursorCredentials.self, from: data),
           let accessToken = credentials.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty
        {
            return accessToken
        }

        let authorizationPrefix = "authorization:"
        if token.lowercased().hasPrefix(authorizationPrefix) {
            token = String(token.dropFirst(authorizationPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bearerPrefix = "bearer "
        if token.lowercased().hasPrefix(bearerPrefix) {
            token = String(token.dropFirst(bearerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return token.isEmpty ? nil : token
    }

    private func resolveAccessToken(for configuration: ProviderAccountConfiguration) throws -> String? {
        if
            let storedSecret = try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            ),
            let accessToken = Self.normalizedAccessToken(from: storedSecret)
        {
            return accessToken
        }

        if
            let credentials = CursorCredentialsParser.parseAuthFile(at: authFilePath),
            let accessToken = Self.normalizedAccessToken(from: credentials.accessToken)
        {
            return accessToken
        }

        return nil
    }

    private static func buildUsageBars(_ usage: CursorCurrentPeriodUsage, fetchedAt: Date) -> [UsageBar] {
        var bars: [UsageBar] = []
        let reset = parseUnixMilliseconds(usage.billingCycleEnd)
        let resetDescription = reset.map { formatReset($0, now: fetchedAt) }
        let billingPeriod = billingPeriod(for: usage, fetchedAt: fetchedAt)

        if let plan = usage.planUsage {
            bars.append(contentsOf: [
                usageBar(
                    label: "Total",
                    percent: plan.totalPercentUsed,
                    reset: reset,
                    resetDescription: resetDescription,
                    billingPeriod: billingPeriod
                ),
                usageBar(
                    label: "Auto",
                    percent: plan.autoPercentUsed,
                    reset: reset,
                    resetDescription: resetDescription,
                    billingPeriod: billingPeriod
                ),
                usageBar(
                    label: "API",
                    percent: plan.apiPercentUsed,
                    reset: reset,
                    resetDescription: resetDescription,
                    billingPeriod: billingPeriod
                ),
            ].compactMap { $0 })
        }

        if
            let onDemand = usage.spendLimitUsage,
            let limit = onDemand.individualLimit,
            limit > 0,
            let remaining = onDemand.individualRemaining
        {
            let used = max(0, limit - remaining)
            bars.append(UsageBar(
                stableKey: "on-demand",
                label: "On-demand \(formatCents(used)) / \(formatCents(limit))",
                used: Double(used) / 100,
                limit: Double(limit) / 100,
                resetDescription: resetDescription,
                resetsAt: reset,
                resetDisplayStyle: .shortLocalDate,
                projectionCurrent: billingPeriod == nil ? nil : Double(used) / 100,
                projectionLimit: billingPeriod == nil ? nil : Double(limit) / 100,
                projectionPeriodStart: billingPeriod?.start,
                projectionPeriodEnd: billingPeriod?.end,
                showProjectionOnCurrentBar: billingPeriod != nil
            ))
        }

        return bars
    }

    private static func hasReachedSpendLimit(_ usage: CursorCurrentPeriodUsage) -> Bool {
        guard
            let onDemand = usage.spendLimitUsage,
            let limit = onDemand.individualLimit,
            let remaining = onDemand.individualRemaining,
            limit > 0
        else {
            return false
        }

        return remaining <= 0
    }

    private static func usageBar(
        label: String,
        percent: Double?,
        reset: Date?,
        resetDescription: String?,
        billingPeriod: CursorBillingPeriod?
    ) -> UsageBar? {
        guard let percent else {
            return nil
        }

        let usedPercent = min(max(percent, 0), 100)
        return UsageBar(
            label: label,
            used: usedPercent,
            limit: 100,
            resetDescription: resetDescription,
            resetsAt: reset,
            resetDisplayStyle: .shortLocalDate,
            projectionCurrent: billingPeriod == nil ? nil : usedPercent / 100,
            projectionLimit: billingPeriod == nil ? nil : 1,
            projectionPeriodStart: billingPeriod?.start,
            projectionPeriodEnd: billingPeriod?.end,
            showProjectionOnCurrentBar: billingPeriod != nil
        )
    }

    private static func billingPeriod(
        for usage: CursorCurrentPeriodUsage,
        fetchedAt: Date
    ) -> CursorBillingPeriod? {
        guard
            let start = parseUnixMilliseconds(usage.billingCycleStart),
            let end = parseUnixMilliseconds(usage.billingCycleEnd),
            start < fetchedAt,
            fetchedAt < end
        else {
            return nil
        }

        return CursorBillingPeriod(start: start, end: end)
    }

    private static func buildUsageSubtitle(_ plan: CursorPlanUsage?) -> String {
        guard let plan else {
            return "Cursor plan usage"
        }

        var parts = ["Included usage"]
        if let auto = plan.autoPercentUsed {
            parts.append("Auto \(formatPercent(auto))")
        }
        if let api = plan.apiPercentUsed {
            parts.append("API \(formatPercent(api))")
        }
        if parts.count == 1, let total = plan.totalPercentUsed {
            parts.append("Total \(formatPercent(total))")
        }

        return parts.joined(separator: " - ")
    }

    private static func parseUnixMilliseconds(_ value: String?) -> Date? {
        guard
            let value,
            let milliseconds = Double(value),
            milliseconds.isFinite,
            milliseconds > 0
        else {
            return nil
        }

        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func formatReset(_ resetAt: Date, now _: Date) -> String {
        "Resets \(UserFacingDateTimeFormatter.current.shortDate(resetAt))"
    }

    private static func formatPercent(_ value: Double) -> String {
        "\(Int(min(max(value, 0), 100).rounded()))%"
    }

    private static func formatCents(_ cents: Double) -> String {
        let dollars = cents / 100
        return currencyFormatter.string(from: NSNumber(value: dollars)) ?? "$0.00"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            fetchedAt: Date()
        )
    }
}

private struct CursorCurrentPeriodUsage: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: CursorPlanUsage?
    let spendLimitUsage: CursorSpendLimitUsage?
}

private struct CursorBillingPeriod {
    let start: Date
    let end: Date
}

private struct CursorPlanUsage: Decodable {
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
}

private struct CursorSpendLimitUsage: Decodable {
    let individualLimit: Double?
    let individualRemaining: Double?
}
