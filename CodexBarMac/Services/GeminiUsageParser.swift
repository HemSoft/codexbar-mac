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
        let cloudaicompanionProject: String?
    }

    private struct Tier: Decodable {
        let id: String?
        let name: String?
    }

    public struct CodeAssistInfo: Equatable, Sendable {
        public let tierName: String?
        public let projectID: String?

        public init(tierName: String? = nil, projectID: String? = nil) {
            self.tierName = tierName
            self.projectID = projectID
        }
    }

    public static func parseCodeAssist(_ data: Data) -> CodeAssistInfo? {
        guard let response = try? JSONDecoder().decode(TierResponse.self, from: data) else {
            return nil
        }

        return CodeAssistInfo(
            tierName: parseTierName(from: response),
            projectID: nonEmptyString(response.cloudaicompanionProject)
        )
    }

    public static func parseTier(_ data: Data) -> String? {
        parseCodeAssist(data)?.tierName
    }

    private static func parseTierName(from response: TierResponse) -> String? {
        if let paidName = nonEmptyString(response.paidTier?.name) {
            return paidName
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

    private static func nonEmptyString(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            guard isQuotaEnforcingTokenType(bucket.tokenType) else {
                continue
            }

            let modelID = bucket.modelId ?? ""
            let remaining = min(max(bucket.remainingFraction ?? 1.0, 0), 1)
            let reset = parseResetDate(bucket.resetTime)

            if isFlashLiteModel(modelID) {
                continue
            }

            if isFlashModel(modelID) {
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

    private static func isQuotaEnforcingTokenType(_ tokenType: String?) -> Bool {
        guard let tokenType else {
            return false
        }

        switch tokenType.uppercased() {
        case "REQUESTS", "INPUT_TOKENS", "OUTPUT_TOKENS":
            return true
        default:
            return false
        }
    }

    private static func isFlashLiteModel(_ modelID: String) -> Bool {
        let normalized = modelID.lowercased()
        return normalized.contains("flash-lite")
            || normalized.contains("flash_lite")
            || normalized.contains("flashlite")
    }

    private static func isFlashModel(_ modelID: String) -> Bool {
        modelID.localizedCaseInsensitiveContains("flash") && !isFlashLiteModel(modelID)
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
