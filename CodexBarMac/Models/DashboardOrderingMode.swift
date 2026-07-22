import Foundation

public enum DashboardOrderingMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case manual
    case smart

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .manual:
            "Manual"
        case .smart:
            "Smart"
        }
    }
}
