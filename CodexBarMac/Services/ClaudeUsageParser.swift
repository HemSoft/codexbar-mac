import Foundation

enum ClaudeUsageIdentity {
    static let allModelsWeeklyStableKey = "weekly-all"
    static let oauthAppsWeeklyStableKey = "weekly-oauth-apps"
    static let allModelsWeeklyLegacyKey = "weekly-usage-limit"
    static let sonnetWeeklyLegacyKey = "sonnet-weekly-limit"
    static let opusWeeklyLegacyKey = "opus-weekly-limit"

    static func legacyScopedWeeklyKey(for stableKey: String?) -> String? {
        switch stableKey {
        case sonnetWeeklyLegacyKey:
            return sonnetWeeklyLegacyKey
        case opusWeeklyLegacyKey:
            return opusWeeklyLegacyKey
        default:
            return nil
        }
    }
}

public enum ClaudeUsageParser {
    private struct UsageResponse: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOAuthApps: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let sevenDaySonnet: UsageWindow?
        let limits: [StructuredLimit]?
        let spend: Spend?
        let extraUsage: ExtraUsage?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOAuthApps = "seven_day_oauth_apps"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case limits
            case spend
            case extraUsage = "extra_usage"
        }
    }

    private struct UsageWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    private struct StructuredLimit: Decodable {
        let kind: String?
        let group: String?
        let percent: Double?
        let resetsAt: String?
        let scope: LimitScope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind
            case group
            case percent
            case resetsAt = "resets_at"
            case scope
            case isActive = "is_active"
        }
    }

    private struct StructuredLimitDefinition {
        let key: String
        let label: String
        let duration: TimeInterval
        let legacyFallbackKey: String?
        let legacySemanticKey: String?
        let usageMessage: String?
    }

    private struct LimitScope: Decodable {
        let model: LimitModel?
    }

    private struct LimitModel: Decodable {
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    private struct Spend: Decodable {
        let enabled: Bool?
        let used: MoneyAmount?
        let limit: MoneyAmount?
        let balance: MoneyAmount?

        enum CodingKeys: String, CodingKey {
            case enabled
            case used
            case limit
            case balance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try? container.decodeIfPresent(Bool.self, forKey: .enabled)
            used = try? container.decodeIfPresent(MoneyAmount.self, forKey: .used)
            limit = try? container.decodeIfPresent(MoneyAmount.self, forKey: .limit)
            balance = try? container.decodeIfPresent(MoneyAmount.self, forKey: .balance)
        }
    }

    private struct MoneyAmount: Decodable {
        let amountMinor: Decimal?
        let currency: String?
        let exponent: Int?

        enum CodingKeys: String, CodingKey {
            case amountMinor = "amount_minor"
            case currency
            case exponent
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            amountMinor = try? container.decodeIfPresent(Decimal.self, forKey: .amountMinor)
            currency = try? container.decodeIfPresent(String.self, forKey: .currency)
            exponent = try? container.decodeIfPresent(Int.self, forKey: .exponent)
        }
    }

    private struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Decimal?
        let usedCredits: Decimal?
        let currency: String?
        let decimalPlaces: Int?
        let disabledReason: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case currency
            case decimalPlaces = "decimal_places"
            case disabledReason = "disabled_reason"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // Lossy optional fields so one malformed monetary value cannot discard usage bars.
            isEnabled = try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)
            monthlyLimit = try? container.decodeIfPresent(Decimal.self, forKey: .monthlyLimit)
            usedCredits = try? container.decodeIfPresent(Decimal.self, forKey: .usedCredits)
            currency = try? container.decodeIfPresent(String.self, forKey: .currency)
            decimalPlaces = try? container.decodeIfPresent(Int.self, forKey: .decimalPlaces)
            disabledReason = try? container.decodeIfPresent(String.self, forKey: .disabledReason)
        }
    }

    public static func parse(
        _ data: Data,
        subscriptionType: String?,
        fetchedAt: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult? {
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return nil
        }

        var bars: [UsageBar] = []
        var semanticKeys = Set<String>()
        let structuredLimits = usage.limits ?? []
        let hasScopedSessionLimit = structuredLimits.contains { limit in
            limit.kind == "session"
                && limit.isActive != false
                && limit.percent != nil
                && sanitizedModelName(limit.scope?.model?.displayName) != nil
        }
        let hasScopedWeeklyLimit = structuredLimits.contains { limit in
            limit.kind == "weekly_scoped"
                && (limit.group == nil || limit.group == "weekly")
                && limit.percent != nil
                && sanitizedModelName(limit.scope?.model?.displayName) != nil
        }

        for limit in structuredLimits where shouldIncludeStructuredLimit(limit) {
            guard let percent = limit.percent else {
                continue
            }

            guard
                let definition = structuredLimitDefinition(
                    for: limit,
                    hasScopedSessionLimit: hasScopedSessionLimit,
                    hasScopedWeeklyLimit: hasScopedWeeklyLimit
                )
            else {
                continue
            }
            if limit.isActive == false,
               structuredLimits.contains(where: { candidate in
                   guard candidate.isActive != false, candidate.percent != nil else {
                       return false
                   }
                   return structuredLimitDefinition(
                       for: candidate,
                       hasScopedSessionLimit: hasScopedSessionLimit,
                       hasScopedWeeklyLimit: hasScopedWeeklyLimit
                   )?.key == definition.key
               })
            {
                continue
            }
            guard semanticKeys.insert(definition.key).inserted else {
                continue
            }
            bars.append(usageBar(
                label: definition.label,
                stableKey: definition.key,
                usedPercent: sanitizedPercent(percent),
                reset: parseReset(limit.resetsAt)
                    ?? definition.legacyFallbackKey.flatMap { legacyReset(for: $0, usage: usage) },
                durationSeconds: definition.duration,
                fetchedAt: fetchedAt,
                dateTimeFormatter: dateTimeFormatter
            ))
            if let legacySemanticKey = definition.legacySemanticKey {
                semanticKeys.insert(legacySemanticKey)
            }
        }

        appendLegacyBar(
            key: "session",
            label: "5 hour usage limit",
            window: usage.fiveHour,
            durationSeconds: 18_000,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: ClaudeUsageIdentity.allModelsWeeklyStableKey,
            label: hasScopedWeeklyLimit
                ? "All models weekly usage limit"
                : "Weekly usage limit",
            window: usage.sevenDay,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: ClaudeUsageIdentity.oauthAppsWeeklyStableKey,
            label: "OAuth apps weekly usage limit",
            window: usage.sevenDayOAuthApps,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: "weekly-scoped-sonnet",
            label: "Sonnet weekly usage limit",
            window: usage.sevenDaySonnet,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: "weekly-scoped-opus",
            label: "Opus weekly usage limit",
            window: usage.sevenDayOpus,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )

        let monetary = usage.spend.map(spendMetrics(from:))
            ?? extraUsageMetrics(from: usage.extraUsage)

        guard !bars.isEmpty || !monetary.metrics.isEmpty || !monetary.messages.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            providerID: .claude,
            title: formatDisplayName(subscriptionType: subscriptionType),
            subtitle: "Live Claude usage",
            bars: bars,
            monetaryMetrics: monetary.metrics,
            usageMessages: uniqueMessages(monetary.messages),
            fetchedAt: fetchedAt
        )
    }

    public static func parseRateLimitHeaders(
        _ fields: [AnyHashable: Any],
        subscriptionType: String?,
        fetchedAt: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult? {
        var bars: [UsageBar] = []
        if let bar = usageBarFromHeaders(
            label: "5 hour usage limit",
            stableKey: "session",
            utilizationKey: "anthropic-ratelimit-unified-5h-utilization",
            resetKey: "anthropic-ratelimit-unified-5h-reset",
            durationSeconds: 18_000,
            fields: fields,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        ) {
            bars.append(bar)
        }

        if let bar = usageBarFromHeaders(
            label: "Weekly usage limit",
            stableKey: ClaudeUsageIdentity.allModelsWeeklyStableKey,
            utilizationKey: "anthropic-ratelimit-unified-7d-utilization",
            resetKey: "anthropic-ratelimit-unified-7d-reset",
            durationSeconds: 604_800,
            fields: fields,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        ) {
            bars.append(bar)
        }

        for scopedBar in scopedWeeklyBarsFromHeaders(
            fields: fields,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        ) {
            bars.append(scopedBar)
        }

        guard !bars.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            providerID: .claude,
            title: formatDisplayName(subscriptionType: subscriptionType),
            subtitle: "Live Claude usage",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    private static func usageBar(
        label: String,
        stableKey: String? = nil,
        window: UsageWindow?,
        durationSeconds: TimeInterval,
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> UsageBar? {
        guard let utilization = window?.utilization else {
            return nil
        }

        return usageBar(
            label: label,
            stableKey: stableKey,
            usedPercent: normalizedOAuthPercent(utilization),
            reset: parseReset(window?.resetsAt),
            durationSeconds: durationSeconds,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
    }

    private static func usageBarFromHeaders(
        label: String,
        stableKey: String? = nil,
        utilizationKey: String,
        resetKey: String,
        durationSeconds: TimeInterval,
        fields: [AnyHashable: Any],
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> UsageBar? {
        guard
            let utilization = doubleHeader(headerValue(fields, key: utilizationKey)),
            let reset = epochHeader(headerValue(fields, key: resetKey))
        else {
            return nil
        }

        return usageBar(
            label: label,
            stableKey: stableKey,
            usedPercent: normalizedHeaderPercent(utilization),
            reset: reset,
            durationSeconds: durationSeconds,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
    }

    private static let scopedWeeklyHeaderModels: [(label: String, stableKey: String, keyVariants: [String])] = [
        ("Sonnet weekly usage limit", "weekly-scoped-sonnet", ["7d-sonnet", "7d_sonnet"]),
        ("Opus weekly usage limit", "weekly-scoped-opus", ["7d-opus", "7d_opus"]),
    ]

    private static func scopedWeeklyBarsFromHeaders(
        fields: [AnyHashable: Any],
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> [UsageBar] {
        var bars: [UsageBar] = []
        var seenLabels = Set<String>()

        for model in scopedWeeklyHeaderModels {
            guard !seenLabels.contains(model.label) else {
                continue
            }

            for variant in model.keyVariants {
                if let bar = usageBarFromHeaders(
                    label: model.label,
                    stableKey: model.stableKey,
                    utilizationKey: "anthropic-ratelimit-unified-\(variant)-utilization",
                    resetKey: "anthropic-ratelimit-unified-\(variant)-reset",
                    durationSeconds: 604_800,
                    fields: fields,
                    fetchedAt: fetchedAt,
                    dateTimeFormatter: dateTimeFormatter
                ) {
                    bars.append(bar)
                    seenLabels.insert(model.label)
                    break
                }
            }
        }

        return bars
    }

    private static func usageBar(
        label: String,
        stableKey: String? = nil,
        usedPercent: Double,
        reset: Date?,
        durationSeconds: TimeInterval,
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> UsageBar {
        return UsageBar(
            stableKey: stableKey,
            label: label,
            used: usedPercent,
            limit: 100,
            resetDescription: reset.map { formatReset(
                $0,
                now: fetchedAt,
                dateTimeFormatter: dateTimeFormatter
            ) },
            resetsAt: reset,
            resetDisplayStyle: .relativeWithLocalTime,
            projectionCurrent: reset == nil ? nil : usedPercent / 100,
            projectionLimit: reset == nil ? nil : 1,
            projectionPeriodStart: reset?.addingTimeInterval(-durationSeconds),
            projectionPeriodEnd: reset,
            showProjectionOnCurrentBar: reset != nil
        )
    }

    private static func appendLegacyBar(
        key: String,
        label: String,
        window: UsageWindow?,
        durationSeconds: TimeInterval,
        semanticKeys: inout Set<String>,
        bars: inout [UsageBar],
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) {
        guard
            !semanticKeys.contains(key),
            let bar = usageBar(
                label: label,
                stableKey: key,
                window: window,
                durationSeconds: durationSeconds,
                fetchedAt: fetchedAt,
                dateTimeFormatter: dateTimeFormatter
            )
        else {
            return
        }
        semanticKeys.insert(key)
        bars.append(bar)
    }

    private static func spendMetrics(
        from spend: Spend
    ) -> (metrics: [ProviderMonetaryMetric], messages: [String]) {
        if spend.enabled == false {
            return ([], ["Usage credits are disabled."])
        }

        let currencyCandidates = [spend.used, spend.limit, spend.balance].compactMap(\.?.currency)
        guard let currency = currencyCandidates.lazy.compactMap({ resolvedCurrencyCode(from: $0) }).first
            ?? resolvedCurrencyCode(from: nil)
        else {
            return ([], ["Usage credits are enabled, but monetary details are temporarily unavailable."])
        }

        let decimalPlaces = [spend.used?.exponent, spend.limit?.exponent, spend.balance?.exponent]
            .compactMap { $0 }
            .first
            ?? currencyDecimalPlaces(currency)

        func matchingAmount(_ amount: MoneyAmount?) -> Decimal? {
            guard let amount, let minor = amount.amountMinor else {
                return nil
            }
            if let reported = amount.currency?.trimmingCharacters(in: .whitespacesAndNewlines),
               !reported.isEmpty,
               resolvedCurrencyCode(from: reported) != currency
            {
                return nil
            }
            return max(minor, 0)
        }

        var metrics: [ProviderMonetaryMetric] = []
        var messages: [String] = spend.enabled == nil
            ? ["Usage-credit enabled status was not reported."]
            : []

        if let spent = matchingAmount(spend.used) {
            metrics.append(ProviderMonetaryMetric(
                kind: .spent,
                label: "Usage credits spent",
                minorUnits: spent,
                currencyCode: currency,
                decimalPlaces: spend.used?.exponent ?? decimalPlaces,
                detail: "Month to date"
            ))
        }

        if let limit = matchingAmount(spend.limit) {
            let places = spend.limit?.exponent ?? decimalPlaces
            metrics.append(ProviderMonetaryMetric(
                kind: .spendLimit,
                label: "Monthly spend limit",
                minorUnits: limit,
                currencyCode: currency,
                decimalPlaces: places,
                detail: "Usage-credit policy cap"
            ))
            if let spent = matchingAmount(spend.used) {
                metrics.append(ProviderMonetaryMetric(
                    kind: .remainingHeadroom,
                    label: "Remaining spend headroom",
                    minorUnits: max(limit - spent, 0),
                    currencyCode: currency,
                    decimalPlaces: places,
                    detail: "Not a prepaid balance"
                ))
                if limit > 0, spent >= limit {
                    messages.append("The monthly usage-credit spend limit has been reached.")
                }
            }
        } else if let balance = matchingAmount(spend.balance) {
            metrics.append(ProviderMonetaryMetric(
                kind: .balance,
                label: "Usage credit balance",
                minorUnits: balance,
                currencyCode: currency,
                decimalPlaces: spend.balance?.exponent ?? decimalPlaces,
                detail: "Prepaid balance"
            ))
        } else if matchingAmount(spend.used) != nil {
            messages.append("Usage credits are enabled with no monthly spend limit reported.")
        }

        if metrics.isEmpty {
            return ([], ["Usage credits are enabled, but monetary details are temporarily unavailable."])
        }
        return (metrics, messages)
    }

    private static func extraUsageMetrics(
        from extraUsage: ExtraUsage?
    ) -> (metrics: [ProviderMonetaryMetric], messages: [String]) {
        guard let extraUsage else {
            return ([], [])
        }
        if extraUsage.isEnabled == false {
            let reason = extraUsage.disabledReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason, !reason.isEmpty {
                return ([], ["Usage credits are disabled: \(reason)."])
            }
            return ([], ["Usage credits are disabled."])
        }
        let reportedCurrency = extraUsage.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currency = resolvedCurrencyCode(from: reportedCurrency), let usedCredits = extraUsage.usedCredits else {
            return ([], ["Usage credits are enabled, but monetary details are temporarily unavailable."])
        }
        let decimalPlaces = extraUsage.decimalPlaces ?? currencyDecimalPlaces(currency)

        let spent = max(usedCredits, 0)
        var metrics = [ProviderMonetaryMetric(
            kind: .spent,
            label: "Usage credits spent",
            minorUnits: spent,
            currencyCode: currency,
            decimalPlaces: decimalPlaces,
            detail: "Month to date"
        )]
        var messages: [String] = extraUsage.isEnabled == nil
            ? ["Usage-credit enabled status was not reported."]
            : []

        if let monthlyLimit = extraUsage.monthlyLimit {
            let limit = max(monthlyLimit, 0)
            metrics.append(ProviderMonetaryMetric(
                kind: .spendLimit,
                label: "Monthly spend limit",
                minorUnits: limit,
                currencyCode: currency,
                decimalPlaces: decimalPlaces,
                detail: "Usage-credit policy cap"
            ))
            metrics.append(ProviderMonetaryMetric(
                kind: .remainingHeadroom,
                label: "Remaining spend headroom",
                minorUnits: max(limit - spent, 0),
                currencyCode: currency,
                decimalPlaces: decimalPlaces,
                detail: "Not a prepaid balance"
            ))
            if limit > 0, spent >= limit {
                messages.append("The monthly usage-credit spend limit has been reached.")
            }
        } else {
            messages.append("Usage credits are enabled with no monthly spend limit reported.")
        }
        return (metrics, messages)
    }

    private static func resolvedCurrencyCode(from reportedCurrency: String?) -> String? {
        let currency = reportedCurrency.flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        let normalized = currency.uppercased()
        guard normalized.count == 3, normalized.allSatisfy(\.isLetter) else {
            return nil
        }
        return normalized
    }

    private static func uniqueMessages(_ messages: [String]) -> [String] {
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
    }

    private static func currencyDecimalPlaces(_ currencyCode: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode.uppercased()
        return formatter.maximumFractionDigits
    }

    // OAuth window utilization is expressed on a 0-100 percentage scale.
    private static func normalizedOAuthPercent(_ value: Double) -> Double {
        sanitizedPercent(value)
    }

    private static func normalizedHeaderPercent(_ value: Double) -> Double {
        sanitizedPercent(min(value, 1) * 100)
    }

    private static func sanitizedPercent(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }

    private static func structuredLimitDefinition(
        for limit: StructuredLimit,
        hasScopedSessionLimit: Bool,
        hasScopedWeeklyLimit: Bool
    ) -> StructuredLimitDefinition? {
        switch limit.kind {
        case "session":
            if let modelName = sanitizedModelName(limit.scope?.model?.displayName) {
                let key = "session-scoped-\(normalizedKey(modelName))"
                return StructuredLimitDefinition(
                    key: key,
                    label: "\(modelName) 5 hour usage limit",
                    duration: 18_000,
                    legacyFallbackKey: nil,
                    legacySemanticKey: nil,
                    usageMessage: nil
                )
            }
            return StructuredLimitDefinition(
                key: "session",
                label: hasScopedSessionLimit
                    ? "Other models 5 hour usage limit"
                    : "5 hour usage limit",
                duration: 18_000,
                legacyFallbackKey: "session",
                legacySemanticKey: nil,
                usageMessage: nil
            )
        case "weekly_all":
            guard limit.group == nil || limit.group == "weekly" else {
                return nil
            }
            return StructuredLimitDefinition(
                key: ClaudeUsageIdentity.allModelsWeeklyStableKey,
                label: hasScopedWeeklyLimit
                    ? "All models weekly usage limit"
                    : "Weekly usage limit",
                duration: 604_800,
                legacyFallbackKey: ClaudeUsageIdentity.allModelsWeeklyStableKey,
                legacySemanticKey: nil,
                usageMessage: nil
            )
        case "weekly_scoped":
            guard
                limit.group == nil || limit.group == "weekly",
                let modelName = sanitizedModelName(limit.scope?.model?.displayName)
            else {
                return nil
            }
            let legacyIdentity = legacyScopedIdentity(for: modelName)
            let key = "weekly-scoped-\(normalizedKey(modelName))"
            return StructuredLimitDefinition(
                key: key,
                label: "\(modelName) weekly usage limit",
                duration: 604_800,
                legacyFallbackKey: legacyIdentity?.semanticKey,
                legacySemanticKey: legacyIdentity?.semanticKey,
                usageMessage: "\(modelName) usage is capped within the all-model weekly allowance."
            )
        default:
            return nil
        }
    }

    private static func shouldIncludeStructuredLimit(_ limit: StructuredLimit) -> Bool {
        switch limit.kind {
        case "weekly_all", "weekly_scoped":
            // Anthropic reports enforceable weekly limits with is_active false.
            return true
        default:
            return limit.isActive != false
        }
    }

    private static func sanitizedModelName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func legacyScopedIdentity(
        for modelName: String
    ) -> (semanticKey: String, stableBarKey: String)? {
        let key = normalizedKey(modelName)
        if key.contains("sonnet") {
            return ("weekly-scoped-sonnet", ClaudeUsageIdentity.sonnetWeeklyLegacyKey)
        }
        if key.contains("opus") {
            return ("weekly-scoped-opus", ClaudeUsageIdentity.opusWeeklyLegacyKey)
        }
        return nil
    }

    private static func legacyReset(for key: String, usage: UsageResponse) -> Date? {
        let window: UsageWindow?
        switch key {
        case "session":
            window = usage.fiveHour
        case "weekly-all":
            window = usage.sevenDay
        case "weekly-oauth-apps":
            window = usage.sevenDayOAuthApps
        case "weekly-scoped-sonnet":
            window = usage.sevenDaySonnet
        case "weekly-scoped-opus":
            window = usage.sevenDayOpus
        default:
            window = nil
        }
        return parseReset(window?.resetsAt)
    }

    private static func parseReset(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        if let epoch = Double(value) {
            let seconds = epoch >= 1_000_000_000_000 ? epoch / 1000 : epoch
            return Date(timeIntervalSince1970: seconds)
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func headerValue(_ fields: [AnyHashable: Any], key: String) -> Any? {
        let normalizedKey = key.lowercased()
        for (fieldKey, value) in fields {
            guard let fieldKey = fieldKey as? String, fieldKey.lowercased() == normalizedKey else {
                continue
            }
            return value
        }
        return nil
    }

    private static func doubleHeader(_ value: Any?) -> Double? {
        if let value = value as? String {
            return Double(value)
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        return nil
    }

    private static func epochHeader(_ value: Any?) -> Date? {
        guard let rawValue = doubleHeader(value) else {
            return nil
        }

        let seconds = rawValue >= 1_000_000_000_000 ? rawValue / 1000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    private static func formatReset(
        _ resetAt: Date,
        now: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> String {
        dateTimeFormatter.resetDescription(
            resetAt: resetAt,
            now: now,
            style: .relativeWithLocalTime,
            fallback: nil
        ) ?? "Resets now"
    }

    private static func formatDisplayName(subscriptionType: String?) -> String {
        guard
            let subscriptionType,
            !subscriptionType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ProviderID.claude.displayName
        }

        return "\(ProviderID.claude.displayName) (\(formatPlanName(subscriptionType)))"
    }

    private static func formatPlanName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
