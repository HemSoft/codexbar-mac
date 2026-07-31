import AppKit
import SwiftUI

public enum DashboardTextSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case standard
    case large
    case extraLarge

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .small:
            "Small"
        case .standard:
            "Default"
        case .large:
            "Large"
        case .extraLarge:
            "Extra Large"
        }
    }

    public var scaleFactor: CGFloat {
        switch self {
        case .small:
            0.9
        case .standard:
            1
        case .large:
            1.15
        case .extraLarge:
            1.3
        }
    }

    public var increased: DashboardTextSize {
        switch self {
        case .small:
            .standard
        case .standard:
            .large
        case .large, .extraLarge:
            .extraLarge
        }
    }

    public var decreased: DashboardTextSize {
        switch self {
        case .small, .standard:
            .small
        case .large:
            .standard
        case .extraLarge:
            .large
        }
    }
}

public struct DashboardPanelSize: Equatable, Sendable {
    public static let defaultSize = DashboardPanelSize(width: 360, height: 520)
    public static let minimumSize = DashboardPanelSize(width: 340, height: 300)
    public static let maximumPersistedSize = DashboardPanelSize(width: 1_600, height: 1_200)

    public let width: CGFloat
    public let height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    public static func normalized(width: Double, height: Double) -> DashboardPanelSize {
        guard width.isFinite, height.isFinite else {
            return .defaultSize
        }

        return DashboardPanelSize(
            width: min(max(CGFloat(width), minimumSize.width), maximumPersistedSize.width),
            height: min(max(CGFloat(height), minimumSize.height), maximumPersistedSize.height)
        )
    }
}

private struct DashboardTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var dashboardTextScale: CGFloat {
        get { self[DashboardTextScaleKey.self] }
        set { self[DashboardTextScaleKey.self] = newValue }
    }
}

enum DashboardFontRole {
    case title2
    case headline
    case body
    case subheadline
    case footnote
    case caption
    case caption2

    var textStyle: NSFont.TextStyle {
        switch self {
        case .title2:
            .title2
        case .headline:
            .headline
        case .body:
            .body
        case .subheadline:
            .subheadline
        case .footnote:
            .footnote
        case .caption:
            .caption1
        case .caption2:
            .caption2
        }
    }

    var defaultWeight: Font.Weight {
        switch self {
        case .headline:
            .semibold
        default:
            .regular
        }
    }
}

private struct DashboardFontModifier: ViewModifier {
    @Environment(\.dashboardTextScale) private var scale

    let role: DashboardFontRole?
    let pointSize: CGFloat?
    let weight: Font.Weight?
    let design: Font.Design

    func body(content: Content) -> some View {
        let baseSize = pointSize
            ?? role.map { NSFont.preferredFont(forTextStyle: $0.textStyle).pointSize }
            ?? NSFont.systemFontSize
        let resolvedWeight = weight ?? role?.defaultWeight ?? .regular
        content.font(.system(size: baseSize * scale, weight: resolvedWeight, design: design))
    }
}

extension View {
    func dashboardFont(
        _ role: DashboardFontRole,
        weight: Font.Weight? = nil,
        design: Font.Design = .default
    ) -> some View {
        modifier(DashboardFontModifier(role: role, pointSize: nil, weight: weight, design: design))
    }

    func dashboardFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(DashboardFontModifier(role: nil, pointSize: size, weight: weight, design: design))
    }
}
