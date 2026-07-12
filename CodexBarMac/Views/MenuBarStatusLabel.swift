import SwiftUI

struct MenuBarStatusLabel: View {
    let severity: UsageSeverity
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        Image(systemName: "chart.bar.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(severity.tint, Color.primary.opacity(0.35))
            .accessibilityLabel("CodexBar")
            .accessibilityValue(severity.accessibilityLabel)
            .contextMenu {
                Button("Refresh", action: onRefresh)
                Button("Settings", action: onOpenSettings)
                Divider()
                Button("Quit", action: onQuit)
            }
    }
}

private extension UsageSeverity {
    var accessibilityLabel: String {
        switch self {
        case .normal:
            "All usage within normal limits"
        case .warning:
            "Usage warning"
        case .critical:
            "Usage critical"
        }
    }
}
