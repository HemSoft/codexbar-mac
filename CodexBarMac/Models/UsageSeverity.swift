import SwiftUI

public enum UsageSeverity: Int, Codable, Comparable, Sendable {
    case normal
    case warning
    case critical

    static let warningThreshold = 0.75
    static let criticalThreshold = 0.90

    public init(fractionUsed: Double) {
        if fractionUsed >= Self.criticalThreshold {
            self = .critical
        } else if fractionUsed >= Self.warningThreshold {
            self = .warning
        } else {
            self = .normal
        }
    }

    public static func < (lhs: UsageSeverity, rhs: UsageSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var tint: Color {
        switch self {
        case .normal:
            .green
        case .warning:
            .orange
        case .critical:
            .red
        }
    }

    public var projectedTint: Color {
        switch self {
        case .normal:
            Color(red: 0x86 / 255.0, green: 0xEF / 255.0, blue: 0xAC / 255.0)
        case .warning:
            Color(red: 0xFA / 255.0, green: 0xCC / 255.0, blue: 0x15 / 255.0)
        case .critical:
            Color(red: 0xF8 / 255.0, green: 0x71 / 255.0, blue: 0x71 / 255.0)
        }
    }
}
