import Foundation

public enum GeminiUsageParser {
    private struct QuotaResponse: Decodable {
        let buckets: [QuotaBucket]?
    }

    private struct QuotaBucket: Decodable {
        let tokenType: String?
        let modelId: String?
        let remainingFraction: Double?
        let resetTime: String?
    }

    private struct TierResponse: Decodable {
        let paidTier: Tier?
        let currentTier: Tier?
    }

    private struct Tier: Decodable {
        let id: String?
        let name: String?
    }

    public static func parseTier(_ data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(TierResponse.self, from: data) else {
            return nil
        }

        if response.paidTier?.id == "g1-pro-tier" {
            return "Paid"
        }

        switch response.currentTier?.id {
        case "standard-tier":
            return "Code Assist"
        case "free-tier":
            return "Free"
        case "legacy-tier":
            return "Legacy"
        default:
            return response.currentTier?.name
        }
    }

    public static func parseQuota(
        _ data: Data,
        tierName: String? = nil,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        guard let response = try? JSONDecoder().decode(QuotaResponse.self, from: data) else {
            return nil
        }

        var lowestProRemaining = 1.0
        var lowestFlashRemaining = 1.0
        var proReset: Date?
        var flashReset: Date?
        var foundPro = false
        var foundFlash = false

        for bucket in response.buckets ?? [] {
            guard bucket.tokenType?.localizedCaseInsensitiveCompare("REQUESTS") == .orderedSame else {
                continue
            }

            let modelID = bucket.modelId ?? ""
            let remaining = min(max(bucket.remainingFraction ?? 1.0, 0), 1)
            let reset = parseResetDate(bucket.resetTime)

            if modelID.localizedCaseInsensitiveContains("flash") {
                if !foundFlash {
                    foundFlash = true
                    lowestFlashRemaining = remaining
                    flashReset = reset
                } else if remaining < lowestFlashRemaining {
                    lowestFlashRemaining = remaining
                    flashReset = reset
                }
            } else if !modelID.isEmpty {
                if !foundPro {
                    foundPro = true
                    lowestProRemaining = remaining
                    proReset = reset
                } else if remaining < lowestProRemaining {
                    lowestProRemaining = remaining
                    proReset = reset
                }
            }
        }

        var bars: [UsageBar] = []
        let tierSuffix = tierName.map { " (\($0))" } ?? ""

        if foundPro {
            bars.append(makeUsageBar(
                label: "Pro\(tierSuffix)",
                remainingFraction: lowestProRemaining,
                resetsAt: proReset,
                fetchedAt: fetchedAt
            ))
        }

        if foundFlash {
            bars.append(makeUsageBar(
                label: "Flash",
                remainingFraction: lowestFlashRemaining,
                resetsAt: flashReset,
                fetchedAt: fetchedAt
            ))
        }

        guard !bars.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            providerID: .gemini,
            title: ProviderID.gemini.displayName,
            subtitle: "Live Gemini CLI usage",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    private static func makeUsageBar(
        label: String,
        remainingFraction: Double,
        resetsAt: Date?,
        fetchedAt: Date
    ) -> UsageBar {
        let used = min(max(1.0 - remainingFraction, 0), 1)
        return UsageBar(
            stableKey: label,
            label: label,
            used: used,
            limit: 1,
            resetDescription: resetDescription(for: resetsAt, now: fetchedAt),
            resetsAt: resetsAt
        )
    }

    private static func parseResetDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        if let date = ISO8601DateFormatter().date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    static func resetDescription(for resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else {
            return nil
        }

        let remaining = max(0, resetsAt.timeIntervalSince(now))
        let totalMinutes = Int(remaining / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours >= 1 {
            return "Resets in \(hours)h \(minutes)m"
        }

        return "Resets in \(minutes)m"
    }
}
