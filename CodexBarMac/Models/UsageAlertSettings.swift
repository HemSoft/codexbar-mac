import Foundation

public struct UsageAlertSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var usageThreshold: Double
    public var balanceThreshold: Double
    public var includesSeverityAlerts: Bool

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case usageThreshold
        case balanceThreshold
        case includesSeverityAlerts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            usageThreshold: try container.decodeIfPresent(Double.self, forKey: .usageThreshold)
                ?? Self.defaultUsageThreshold,
            balanceThreshold: try container.decodeIfPresent(Double.self, forKey: .balanceThreshold)
                ?? Self.defaultBalanceThreshold,
            includesSeverityAlerts: try container.decodeIfPresent(Bool.self, forKey: .includesSeverityAlerts)
                ?? true
        )
    }

    public init(
        isEnabled: Bool = false,
        usageThreshold: Double = Self.defaultUsageThreshold,
        balanceThreshold: Double = Self.defaultBalanceThreshold,
        includesSeverityAlerts: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.usageThreshold = Self.normalizedUsageThreshold(usageThreshold)
        self.balanceThreshold = Self.normalizedBalanceThreshold(balanceThreshold)
        self.includesSeverityAlerts = includesSeverityAlerts
    }

    public static let defaultUsageThreshold = 0.80
    public static let defaultBalanceThreshold = 5.00

    public static func normalizedUsageThreshold(_ value: Double) -> Double {
        min(max(value, 0.01), 1.0)
    }

    public static func normalizedBalanceThreshold(_ value: Double) -> Double {
        max(value, 0)
    }
}
