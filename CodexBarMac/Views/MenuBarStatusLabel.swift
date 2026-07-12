import AppKit
import SwiftUI

struct MenuBarStatusLabel: View {
    let severity: UsageSeverity
    let isRefreshEnabled: Bool
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        Image(systemName: "chart.bar.fill")
            .symbolRenderingMode(.palette)
            .foregroundStyle(severity.tint, Color.primary.opacity(0.35))
            .accessibilityLabel("CodexBar")
            .accessibilityValue(severity.accessibilityLabel)
            .background(
                StatusBarRightClickMenu(
                    isRefreshEnabled: isRefreshEnabled,
                    onRefresh: onRefresh,
                    onOpenSettings: onOpenSettings,
                    onQuit: onQuit
                )
            )
    }
}

private struct StatusBarRightClickMenu: NSViewRepresentable {
    let isRefreshEnabled: Bool
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isRefreshEnabled: isRefreshEnabled,
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
        context.coordinator.isRefreshEnabled = isRefreshEnabled
        context.coordinator.onRefresh = onRefresh
        context.coordinator.onOpenSettings = onOpenSettings
        context.coordinator.onQuit = onQuit
        context.coordinator.rebuildMenu()
        nsView.coordinator = context.coordinator
        nsView.scheduleAttachment()
    }

    final class Coordinator: NSObject {
        var isRefreshEnabled: Bool
        var onRefresh: () -> Void
        var onOpenSettings: () -> Void
        var onQuit: () -> Void

        private weak var statusBarButton: NSStatusBarButton?
        private var eventMonitor: Any?
        private var menu: NSMenu?

        init(
            isRefreshEnabled: Bool,
            onRefresh: @escaping () -> Void,
            onOpenSettings: @escaping () -> Void,
            onQuit: @escaping () -> Void
        ) {
            self.isRefreshEnabled = isRefreshEnabled
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

        @objc private func refreshClicked() {
            onRefresh()
        }

        @objc private func settingsClicked() {
            onOpenSettings()
        }

        @objc private func quitClicked() {
            onQuit()
        }

        private func installEventMonitor() {
            guard eventMonitor == nil else {
                return
            }

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseUp) { [weak self] event in
                guard
                    let self,
                    let button = self.statusBarButton,
                    let menu = self.menu,
                    let window = button.window,
                    event.window === window
                else {
                    return event
                }

                let locationInButton = button.convert(event.locationInWindow, from: nil)
                guard button.bounds.contains(locationInButton) else {
                    return event
                }

                NSApp.activate(ignoringOtherApps: true)
                menu.popUp(
                    positioning: nil,
                    at: NSPoint(x: 0, y: button.bounds.height + 4),
                    in: button
                )
                return nil
            }
        }

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
