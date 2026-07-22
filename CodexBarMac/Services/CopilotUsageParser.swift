import Foundation

public enum CopilotUsageParser {
    public static func parse(_ data: Data, fetchedAt: Date = Date()) -> ProviderUsageResult? {
        guard let response = try? JSONDecoder().decode(CopilotUserResponse.self, from: data) else {
            return nil
        }

        let title = formatDisplayName(username: response.login, plan: response.copilotPlan)
        let reset = parseReset(from: response, fetchedAt: fetchedAt)
        var bars: [UsageBar] = []

        if let premium = response.quotaSnapshots?.premiumInteractions,
           shouldIncludePremiumSnapshot(response: response, snapshot: premium) {
            let label = premiumInteractionsLabel(response: response, snapshot: premium)
            bars.append(makeUsageBar(snapshot: premium, label: label, reset: reset, fetchedAt: fetchedAt))
        }

        if let chat = response.quotaSnapshots?.chat, !chat.unlimited, chat.entitlement > 0 {
            bars.append(makeUsageBar(snapshot: chat, label: "Chat", reset: reset, fetchedAt: fetchedAt))
        }

        return ProviderUsageResult(
            providerID: .copilot,
            title: title,
            subtitle: reset.description ?? "Live GitHub Copilot usage",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    public static func username(from data: Data) -> String? {
        (try? JSONDecoder().decode(CopilotUserResponse.self, from: data))?.login
    }

    private static func premiumInteractionsLabel(
        response: CopilotUserResponse,
        snapshot: CopilotQuotaSnapshot
    ) -> String {
        usesAICredits(response: response, snapshot: snapshot) ? "AI credits" : "Premium interactions"
    }

    private static func usesAICredits(response: CopilotUserResponse, snapshot: CopilotQuotaSnapshot) -> Bool {
        response.tokenBasedBilling == true || snapshot.tokenBasedBilling == true
    }

    private static func shouldIncludePremiumSnapshot(
        response: CopilotUserResponse,
        snapshot: CopilotQuotaSnapshot
    ) -> Bool {
        guard usesAICredits(response: response, snapshot: snapshot) else {
            return true
        }

        return !(snapshot.entitlement == 0 && snapshot.remaining == 0 && !snapshot.unlimited)
    }

    private static func makeUsageBar(
        snapshot: CopilotQuotaSnapshot,
        label: String,
        reset: CopilotReset,
        fetchedAt: Date
    ) -> UsageBar {
        if snapshot.unlimited && snapshot.hasQuota == false {
            return UsageBar(
                label: "\(label) - pool exhausted",
                used: 1,
                limit: 1,
                resetDescription: reset.description,
                resetsAt: reset.date
            )
        }

        guard snapshot.entitlement > 0 else {
            return UsageBar(
                label: snapshot.unlimited ? "\(label) - unlimited" : "\(label) - no quota",
                used: 0,
                limit: 0,
                resetDescription: reset.description,
                resetsAt: reset.date
            )
        }

        let used = max(0, snapshot.entitlement - snapshot.remaining)
        let formattedLabel = "\(label) (\(formatNumber(used)) / \(formatNumber(snapshot.entitlement)))"
        let projectionPeriod = monthlyProjectionPeriod(resetDate: reset.date, fetchedAt: fetchedAt)
        return UsageBar(
            label: formattedLabel,
            used: Double(used),
            limit: Double(snapshot.entitlement),
            resetDescription: reset.description ?? formatMonthlyReset(projectionPeriod.end, fetchedAt: fetchedAt),
            resetsAt: projectionPeriod.end,
            projectionCurrent: Double(used),
            projectionLimit: Double(snapshot.entitlement),
            projectionPeriodStart: projectionPeriod.start,
            projectionPeriodEnd: projectionPeriod.end,
            showProjectionOnCurrentBar: true
        )
    }

    private static func monthlyProjectionPeriod(resetDate: Date?, fetchedAt: Date) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        if let resetDate {
            return (calendar.date(byAdding: .month, value: -1, to: resetDate) ?? resetDate, resetDate)
        }

        let components = calendar.dateComponents([.year, .month], from: fetchedAt)
        let start = calendar.date(from: components) ?? fetchedAt
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return (start, end)
    }

    private static func formatDisplayName(username: String?, plan: String?) -> String {
        let base = username.map { "GitHub Copilot (\($0))" } ?? ProviderID.copilot.displayName
        guard let plan else {
            return base
        }

        let planLabel: String
        switch plan {
        case "enterprise":
            planLabel = "Ent"
        case "individual_pro":
            planLabel = "Pro"
        case "business":
            planLabel = "Biz"
        default:
            planLabel = plan.replacingOccurrences(of: "_", with: " ")
        }

        return "\(base) - \(planLabel)"
    }

    private static func parseReset(from response: CopilotUserResponse, fetchedAt: Date) -> CopilotReset {
        if let resetDateUTC = response.quotaResetDateUTC,
           let date = parseResetDate(resetDateUTC) {
            return makeReset(date: date, fetchedAt: fetchedAt)
        }

        if let resetDate = response.quotaResetDate,
           let date = parseDateOnlyReset(resetDate) {
            return makeReset(date: date, fetchedAt: fetchedAt)
        }

        return CopilotReset(date: nil, description: nil)
    }

    private static func makeReset(date: Date, fetchedAt: Date) -> CopilotReset {
        let remaining = date.timeIntervalSince(fetchedAt)
        let description: String
        if remaining < 0 {
            description = "Reset overdue"
        } else if remaining < 24 * 60 * 60 {
            let hours = Int(remaining / 3600)
            let minutes = Int((remaining.truncatingRemainder(dividingBy: 3600)) / 60)
            description = "Resets in \(hours)h \(minutes)m"
        } else if remaining < 2 * 24 * 60 * 60 {
            description = "Resets tomorrow"
        } else {
            description = "Resets in \(Int(remaining / (24 * 60 * 60)))d"
        }

        return CopilotReset(date: date, description: description)
    }

    private static func parseDateOnlyReset(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func parseResetDate(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        return ISO8601DateFormatter().date(from: value)
    }

    private static func formatMonthlyReset(_ date: Date, fetchedAt: Date) -> String {
        let remaining = date.timeIntervalSince(fetchedAt)
        if remaining <= 0 {
            return "Reset overdue"
        }

        let days = Int(remaining / 86_400)
        let hours = Int(remaining.truncatingRemainder(dividingBy: 86_400) / 3_600)
        if days > 0 {
            return "Resets in \(days)d \(hours)h"
        }

        let minutes = Int(remaining.truncatingRemainder(dividingBy: 3_600) / 60)
        return "Resets in \(hours)h \(minutes)m"
    }

    private static func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    fileprivate static func formatDecimalNumber(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    fileprivate static func formatRelativeReset(_ date: Date, fetchedAt: Date) -> String {
        formatMonthlyReset(date, fetchedAt: fetchedAt)
    }
}

public enum CopilotBillingUsageParser {
    public static func parse(
        _ data: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date(),
        totalAllotment: Double? = nil
    ) -> ProviderUsageResult? {
        guard let response = try? JSONDecoder().decode(CopilotBillingUsageResponse.self, from: data) else {
            return nil
        }

        let consumed = response.usageItems
            .filter { item in
                item.product?.localizedCaseInsensitiveCompare("Copilot") == .orderedSame
                    || item.sku?.localizedCaseInsensitiveContains("Copilot") == true
            }
            .reduce(0) { $0 + $1.grossQuantity }
        let periodStart = response.timePeriod.periodStart ?? monthStart(for: fetchedAt)
        let periodEnd = monthEnd(after: periodStart)
        let resetDescription = CopilotUsageParser.formatRelativeReset(periodEnd, fetchedAt: fetchedAt)
        let total = totalAllotment ?? configuration.copilotTotalAllotment
        let bars = makeBars(
            consumed: consumed,
            total: total,
            periodStart: periodStart,
            periodEnd: periodEnd,
            resetDescription: resetDescription,
            fetchedAt: fetchedAt
        )
        let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .copilot,
            title: configuration.displayName,
            subtitle: organization.isEmpty
                ? "Live GitHub Copilot organization usage"
                : "Live GitHub Copilot usage for \(organization)",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    private static func makeBars(
        consumed: Double,
        total: Double?,
        periodStart: Date,
        periodEnd: Date,
        resetDescription: String,
        fetchedAt: Date
    ) -> [UsageBar] {
        guard let total, total > 0 else {
            let projected = projectedPeriodEndUsage(
                consumed: consumed,
                periodStart: periodStart,
                periodEnd: periodEnd,
                now: fetchedAt
            )
            let projectionDescription = projected > consumed
                ? "Projected month end at current pace - \(CopilotUsageParser.formatDecimalNumber(projected)) AI credits"
                : nil
            return [
                UsageBar(
                    label: "AI credits used (\(CopilotUsageParser.formatDecimalNumber(consumed)))",
                    used: consumed,
                    limit: 0,
                    resetDescription: resetDescription,
                    resetsAt: periodEnd,
                    projectionCurrent: consumed,
                    projectionPeriodStart: periodStart,
                    projectionPeriodEnd: periodEnd,
                    projectionDescriptionOverride: projectionDescription
                ),
            ]
        }

        return [
            UsageBar(
                label: "Current AI credits (\(CopilotUsageParser.formatDecimalNumber(consumed)) / \(CopilotUsageParser.formatDecimalNumber(total)))",
                used: consumed,
                limit: total,
                resetDescription: resetDescription,
                resetsAt: periodEnd,
                projectionCurrent: consumed,
                projectionLimit: total,
                projectionPeriodStart: periodStart,
                projectionPeriodEnd: periodEnd,
                showProjectionOnCurrentBar: true
            ),
        ]
    }

    private static func monthStart(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private static func monthEnd(after periodStart: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .month, value: 1, to: periodStart) ?? periodStart
    }

    private static func projectedPeriodEndUsage(
        consumed: Double,
        periodStart: Date,
        periodEnd: Date,
        now: Date
    ) -> Double {
        guard now > periodStart, now < periodEnd, consumed > 0 else {
            return consumed
        }

        let elapsed = now.timeIntervalSince(periodStart)
        let total = periodEnd.timeIntervalSince(periodStart)
        return consumed * total / elapsed
    }
}

public enum CopilotSeatCountParser {
    public static func parse(_ data: Data) -> Int? {
        (try? JSONDecoder().decode(CopilotBillingSeatsResponse.self, from: data))?
            .seatBreakdown?
            .total
    }
}

private struct CopilotBillingUsageResponse: Decodable {
    let timePeriod: CopilotBillingTimePeriod
    let usageItems: [CopilotBillingUsageItem]
}

private struct CopilotBillingTimePeriod: Decodable {
    let year: Int?
    let month: Int?
    let day: Int?

    var periodStart: Date? {
        guard let year, let month else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day ?? 1))
    }
}

private struct CopilotBillingUsageItem: Decodable {
    let product: String?
    let sku: String?
    let grossQuantity: Double
}

private struct CopilotBillingSeatsResponse: Decodable {
    let seatBreakdown: CopilotSeatBreakdown?

    enum CodingKeys: String, CodingKey {
        case seatBreakdown = "seat_breakdown"
    }
}

private struct CopilotSeatBreakdown: Decodable {
    let total: Int?
}

private struct CopilotUserResponse: Decodable {
    let login: String?
    let copilotPlan: String?
    let tokenBasedBilling: Bool?
    let quotaResetDate: String?
    let quotaResetDateUTC: String?
    let quotaSnapshots: CopilotQuotaSnapshots?

    enum CodingKeys: String, CodingKey {
        case login
        case copilotPlan = "copilot_plan"
        case tokenBasedBilling = "token_based_billing"
        case quotaResetDate = "quota_reset_date"
        case quotaResetDateUTC = "quota_reset_date_utc"
        case quotaSnapshots = "quota_snapshots"
    }
}

private struct CopilotQuotaSnapshots: Decodable {
    let premiumInteractions: CopilotQuotaSnapshot?
    let chat: CopilotQuotaSnapshot?

    enum CodingKeys: String, CodingKey {
        case premiumInteractions = "premium_interactions"
        case chat
    }
}

private struct CopilotQuotaSnapshot: Decodable {
    let entitlement: Int
    let remaining: Int
    let unlimited: Bool
    let hasQuota: Bool?
    let tokenBasedBilling: Bool?

    enum CodingKeys: String, CodingKey {
        case entitlement
        case remaining
        case unlimited
        case hasQuota = "has_quota"
        case tokenBasedBilling = "token_based_billing"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entitlement = try container.decodeIfPresent(Int.self, forKey: .entitlement) ?? 0
        remaining = try container.decodeIfPresent(Int.self, forKey: .remaining) ?? 0
        unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
        hasQuota = try container.decodeIfPresent(Bool.self, forKey: .hasQuota)
        tokenBasedBilling = try container.decodeIfPresent(Bool.self, forKey: .tokenBasedBilling)
    }
}

private struct CopilotReset {
    let date: Date?
    let description: String?
}
