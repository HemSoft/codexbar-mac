import Foundation

public enum CopilotUsageParser {
    public static func parse(_ data: Data, fetchedAt: Date = Date()) -> ProviderUsageResult? {
        guard let response = try? JSONDecoder().decode(CopilotUserResponse.self, from: data) else {
            return nil
        }

        let title = formatDisplayName(username: response.login, plan: response.copilotPlan)
        let reset = parseReset(response.quotaResetDateUTC, fetchedAt: fetchedAt)
        var bars: [UsageBar] = []

        if let premium = response.quotaSnapshots?.premiumInteractions {
            bars.append(makeUsageBar(snapshot: premium, label: "Premium interactions", reset: reset, fetchedAt: fetchedAt))
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

    private static func makeUsageBar(
        snapshot: CopilotQuotaSnapshot,
        label: String,
        reset: CopilotReset,
        fetchedAt: Date
    ) -> UsageBar {
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

    private static func parseReset(_ resetDateUTC: String?, fetchedAt: Date) -> CopilotReset {
        guard
            let resetDateUTC,
            let date = ISO8601DateFormatter().date(from: resetDateUTC)
        else {
            return CopilotReset(date: nil, description: nil)
        }

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
}

private struct CopilotUserResponse: Decodable {
    let login: String?
    let copilotPlan: String?
    let quotaResetDateUTC: String?
    let quotaSnapshots: CopilotQuotaSnapshots?

    enum CodingKeys: String, CodingKey {
        case login
        case copilotPlan = "copilot_plan"
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
}

private struct CopilotReset {
    let date: Date?
    let description: String?
}
