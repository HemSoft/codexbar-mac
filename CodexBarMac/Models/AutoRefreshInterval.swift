import Foundation

public enum AutoRefreshInterval: Int, CaseIterable, Identifiable, Codable, Sendable {
    case off = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600

    public var id: Int {
        rawValue
    }

    public var seconds: TimeInterval? {
        rawValue > 0 ? TimeInterval(rawValue) : nil
    }

    public var displayName: String {
        switch self {
        case .off:
            "Off"
        case .oneMinute:
            "1 min"
        case .fiveMinutes:
            "5 min"
        case .fifteenMinutes:
            "15 min"
        case .thirtyMinutes:
            "30 min"
        case .oneHour:
            "1 hour"
        }
    }
}
