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

public enum HistorySamplingInterval: Int, CaseIterable, Identifiable, Codable, Sendable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600
    case twoHours = 7_200
    case fourHours = 14_400
    case eightHours = 28_800
    case twelveHours = 43_200
    case oneDay = 86_400

    public var id: Int {
        rawValue
    }

    public var seconds: TimeInterval {
        TimeInterval(rawValue)
    }

    public var displayName: String {
        switch self {
        case .fifteenMinutes:
            "15 min"
        case .thirtyMinutes:
            "30 min"
        case .oneHour:
            "1 hour"
        case .twoHours:
            "2 hours"
        case .fourHours:
            "4 hours"
        case .eightHours:
            "8 hours"
        case .twelveHours:
            "12 hours"
        case .oneDay:
            "1 day"
        }
    }
}
