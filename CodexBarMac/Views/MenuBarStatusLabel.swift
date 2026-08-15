import AppKit
import SwiftUI

enum StatusBarRightClickRoute: Equatable {
    case passThrough
    case openMenu

    static func resolve(
        eventWindowMatchesButton: Bool,
        locationIsInsideButton: Bool
    ) -> Self {
        guard eventWindowMatchesButton, locationIsInsideButton else {
            return .passThrough
        }

        return .openMenu
    }
}

struct MenuBarStatusLabel: View {
    let severity: UsageSeverity
    let hasPendingUpdate: Bool
    let isRefreshEnabled: Bool
    let onShowUpdate: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: "chart.bar.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(severity.tint, Color.primary.opacity(0.35))

            if hasPendingUpdate {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .overlay {
                        Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1)
                    }
                    .offset(x: 2, y: -2)
            }
        }
            .accessibilityLabel("CodexBar")
            .accessibilityValue(accessibilityValue)
            .background(
                StatusBarRightClickMenu(
                    hasPendingUpdate: hasPendingUpdate,
                    isRefreshEnabled: isRefreshEnabled,
                    onShowUpdate: onShowUpdate,
                    onRefresh: onRefresh,
                    onOpenSettings: onOpenSettings,
                    onQuit: onQuit
                )
            )
    }

    private var accessibilityValue: String {
        guard hasPendingUpdate else {
            return severity.accessibilityLabel
        }

        return "Update available. \(severity.accessibilityLabel)"
    }
}

private struct StatusBarRightClickMenu: NSViewRepresentable {
    let hasPendingUpdate: Bool
    let isRefreshEnabled: Bool
    let onShowUpdate: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            hasPendingUpdate: hasPendingUpdate,
            isRefreshEnabled: isRefreshEnabled,
            onShowUpdate: onShowUpdate,
            onRefresh: onRefresh,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
    }

    func makeNSView(context: Context) -> MenuAnchorView {
        let view = MenuAnchorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MenuAnchorView, context: Context) {
        context.coordinator.hasPendingUpdate = hasPendingUpdate
        context.coordinator.isRefreshEnabled = isRefreshEnabled
        context.coordinator.onShowUpdate = onShowUpdate
        context.coordinator.onRefresh = onRefresh
        context.coordinator.onOpenSettings = onOpenSettings
        context.coordinator.onQuit = onQuit
        context.coordinator.rebuildMenu()
        nsView.coordinator = context.coordinator
        nsView.scheduleAttachment()
    }

    final class Coordinator: NSObject {
        var hasPendingUpdate: Bool
        var isRefreshEnabled: Bool
        var onShowUpdate: () -> Void
        var onRefresh: () -> Void
        var onOpenSettings: () -> Void
        var onQuit: () -> Void

        private weak var statusBarButton: NSStatusBarButton?
        private var eventMonitor: Any?
        private var menu: NSMenu?

        init(
            hasPendingUpdate: Bool,
            isRefreshEnabled: Bool,
            onShowUpdate: @escaping () -> Void,
            onRefresh: @escaping () -> Void,
            onOpenSettings: @escaping () -> Void,
            onQuit: @escaping () -> Void
        ) {
            self.hasPendingUpdate = hasPendingUpdate
            self.isRefreshEnabled = isRefreshEnabled
            self.onShowUpdate = onShowUpdate
            self.onRefresh = onRefresh
            self.onOpenSettings = onOpenSettings
            self.onQuit = onQuit
            super.init()
            rebuildMenu()
        }

        deinit {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
        }

        @MainActor
        func attachIfNeeded(from view: NSView) {
            guard statusBarButton == nil,
                  let button = Self.findStatusBarButton(startingAt: view)
            else {
                return
            }

            statusBarButton = button
            installEventMonitor()
        }

        func rebuildMenu() {
            let menu = NSMenu()

            if hasPendingUpdate {
                let updateItem = NSMenuItem(
                    title: "Update Available…",
                    action: #selector(showUpdateClicked),
                    keyEquivalent: ""
                )
                updateItem.target = self
                menu.addItem(updateItem)
                menu.addItem(.separator())
            }

            let refreshItem = NSMenuItem(
                title: "Refresh",
                action: #selector(refreshClicked),
                keyEquivalent: "r"
            )
            refreshItem.target = self
            refreshItem.isEnabled = isRefreshEnabled
            menu.addItem(refreshItem)

            let settingsItem = NSMenuItem(
                title: "Settings",
                action: #selector(settingsClicked),
                keyEquivalent: ","
            )
            settingsItem.target = self
            menu.addItem(settingsItem)

            menu.addItem(.separator())

            let quitItem = NSMenuItem(
                title: "Quit",
                action: #selector(quitClicked),
                keyEquivalent: "q"
            )
            quitItem.target = self
            menu.addItem(quitItem)

            self.menu = menu
        }

        @objc private func showUpdateClicked() {
            onShowUpdate()
        }

        @objc private func refreshClicked() {
            onRefresh()
        }

        @objc private func settingsClicked() {
            onOpenSettings()
        }

        @objc private func quitClicked() {
            onQuit()
        }

        @MainActor
        private func installEventMonitor() {
            guard eventMonitor == nil else {
                return
            }

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
                let shouldConsumeEvent = MainActor.assumeIsolated {
                    self?.handleRightMouseUp(event) ?? false
                }
                return shouldConsumeEvent ? nil : event
            }
        }

        @MainActor
        private func handleRightMouseUp(_ event: NSEvent) -> Bool {
            guard
                let button = statusBarButton,
                let menu,
                let window = button.window
            else {
                return false
            }

            let eventWindowMatchesButton = event.window === window
            let locationIsInsideButton = eventWindowMatchesButton
                && button.bounds.contains(button.convert(event.locationInWindow, from: nil))
            let route = StatusBarRightClickRoute.resolve(
                eventWindowMatchesButton: eventWindowMatchesButton,
                locationIsInsideButton: locationIsInsideButton
            )
            guard route == .openMenu else {
                return false
            }

            NSApp.activate(ignoringOtherApps: true)
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: button.bounds.height + 4),
                in: button
            )
            return true
        }

        @MainActor
        private static func findStatusBarButton(startingAt view: NSView) -> NSStatusBarButton? {
            var current: NSView? = view
            while let candidate = current {
                if let button = candidate as? NSStatusBarButton {
                    return button
                }
                current = candidate.superview
            }
            return nil
        }
    }

    final class MenuAnchorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleAttachment()
        }

        func scheduleAttachment() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let coordinator else {
                    return
                }
                coordinator.attachIfNeeded(from: self)
            }
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
