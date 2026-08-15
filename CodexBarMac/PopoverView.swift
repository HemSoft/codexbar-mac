import AppKit
import Sparkle
import SwiftUI

enum DashboardPresentation {
    case menuBar
    case detached
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @ObservedObject var updateReminder: SparkleUpdateReminderCoordinator

    var body: some View {
        DashboardView(
            model: model,
            updater: updater,
            updateReminder: updateReminder,
            presentation: .menuBar
        )
            .frame(
                minWidth: DashboardPanelSize.minimumSize.width,
                idealWidth: model.configurationStore.menuBarDashboardSize.width,
                minHeight: DashboardPanelSize.minimumSize.height,
                idealHeight: model.configurationStore.menuBarDashboardSize.height
            )
            .background(
                MenuBarPanelConfigurator(configurationStore: model.configurationStore)
                    .frame(width: 0, height: 0)
            )
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    let updater: SPUUpdater
    @ObservedObject var updateReminder: SparkleUpdateReminderCoordinator
    let presentation: DashboardPresentation

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var isConfirmingHistoryReset = false

    private var configurationStore: ProviderConfigurationStore {
        model.configurationStore
    }

    var body: some View {
        let usageAlertsByAccountID = model.currentUsageAlertsByAccountID
        let scale = configurationStore.dashboardTextSize.scaleFactor

        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 10 * scale) {
                    if let historyError = model.historyStore.lastError {
                        VStack(alignment: .leading, spacing: 8 * scale) {
                            Label(historyError, systemImage: "exclamationmark.triangle.fill")
                                .dashboardFont(.footnote)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("usage-history-persistence-error")

                            if model.historyStore.requiresRecovery {
                                Button("Reset History", role: .destructive) {
                                    isConfirmingHistoryReset = true
                                }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("reset-corrupted-usage-history")
                            }
                        }
                    }

                    if model.displayedResults.isEmpty {
                        emptyState
                    } else {
                        ForEach(model.displayedResults) { result in
                            ProviderUsageCard(
                                result: result,
                                historyOptions: model.historyStore.historySeriesOptions(for: result),
                                alerts: usageAlertsByAccountID[result.accountID] ?? [],
                                isHistoryEnabled: configurationStore
                                    .configuration(accountID: result.accountID)?
                                    .showsHistory ?? true
                            )
                        }
                    }
                }
                .padding(.horizontal, 12 * scale)
                .padding(.vertical, 10 * scale)
            }

            Divider()

            HStack {
                if updateReminder.hasPendingScheduledUpdate {
                    Button {
                        updateReminder.showPendingUpdate(using: updater)
                    } label: {
                        Label("Update Available…", systemImage: "arrow.down.circle.fill")
                    }
                    .accessibilityIdentifier("show-pending-update")
                } else {
                    CheckForUpdatesButton(updater: updater)
                }
                Spacer()
            }
            .padding(.horizontal, 12 * scale)
            .padding(.vertical, 8 * scale)
        }
        .frame(
            minWidth: DashboardPanelSize.minimumSize.width,
            minHeight: DashboardPanelSize.minimumSize.height
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .font(.system(size: NSFont.systemFontSize * scale))
        .environment(\.dashboardTextScale, scale)
        .preferredColorScheme(configurationStore.appAppearance.colorScheme)
        .confirmationDialog(
            "Reset unreadable usage history?",
            isPresented: $isConfirmingHistoryReset,
            titleVisibility: .visible
        ) {
            Button("Reset History", role: .destructive) {
                model.historyStore.discardCorruptedHistory()
            }
            .accessibilityIdentifier("confirm-reset-corrupted-usage-history")
        } message: {
            Text("This permanently discards the unreadable history so new usage can be recorded.")
        }
        .onChange(of: configurationStore.autoRefreshInterval) { _, _ in
            model.updateAutoRefresh()
        }
    }

    private var header: some View {
        let scale = configurationStore.dashboardTextSize.scaleFactor

        return HStack(spacing: 8 * scale) {
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text("CodexBar")
                    .dashboardFont(.headline)

                Text(model.lastRefreshedText)
                    .dashboardFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await model.refresh()
                }
            } label: {
                Group {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .frame(width: 32 * scale, height: 32 * scale)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Refresh usage")
            .accessibilityLabel("Refresh usage")
            .disabled(model.isRefreshing)

            Menu {
                Button("Zoom In") {
                    configurationStore.updateDashboardTextSize(
                        configurationStore.dashboardTextSize.increased
                    )
                }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(configurationStore.dashboardTextSize == .extraLarge)

                Button("Zoom Out") {
                    configurationStore.updateDashboardTextSize(
                        configurationStore.dashboardTextSize.decreased
                    )
                }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(configurationStore.dashboardTextSize == .small)

                Divider()

                Button("Actual Size") {
                    configurationStore.updateDashboardTextSize(.standard)
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(configurationStore.dashboardTextSize == .standard)
            } label: {
                Image(systemName: "textformat.size")
                    .frame(width: 32 * scale, height: 32 * scale)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Dashboard Text Size")
            .accessibilityLabel("Dashboard Text Size")

            if presentation == .menuBar {
                Button {
                    openWindow(id: "dashboard")
                } label: {
                    Image(systemName: "rectangle.on.rectangle")
                        .frame(width: 32 * scale, height: 32 * scale)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Open Dashboard Window")
                .accessibilityLabel("Open Dashboard Window")
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 32 * scale, height: 32 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")

            Button {
                model.quit()
            } label: {
                Image(systemName: "power")
                    .frame(width: 32 * scale, height: 32 * scale)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Quit CodexBar")
            .accessibilityLabel("Quit CodexBar")
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 8 * scale)
    }

    private var emptyState: some View {
        let scale = configurationStore.dashboardTextSize.scaleFactor

        return VStack(spacing: 8 * scale) {
            Image(systemName: "chart.bar.xaxis")
                .dashboardFont(.title2)
                .foregroundStyle(.secondary)

            Text("No providers to show")
                .dashboardFont(.headline)

            Text("Enable providers in Settings to see usage cards here.")
                .dashboardFont(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24 * scale)
    }
}

private struct MenuBarPanelConfigurator: NSViewRepresentable {
    @ObservedObject var configurationStore: ProviderConfigurationStore

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        view.onWindowChange = { window in
            context.coordinator.attach(to: window, configurationStore: configurationStore)
        }
        return view
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        view.onWindowChange = { window in
            context.coordinator.attach(to: window, configurationStore: configurationStore)
        }
        context.coordinator.configure(configurationStore: configurationStore)
    }

    static func dismantleNSView(_ view: WindowProbeView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.detach()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var resizeObserver: NSObjectProtocol?
        private var restoredWindow: NSWindow?
        private weak var configurationStore: ProviderConfigurationStore?

        func attach(to window: NSWindow?, configurationStore: ProviderConfigurationStore) {
            guard self.window !== window else {
                configure(configurationStore: configurationStore)
                return
            }

            detach()
            self.window = window
            self.configurationStore = configurationStore
            configure(configurationStore: configurationStore)

            guard let window else {
                return
            }

            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self, weak window] _ in
                Task { @MainActor in
                    guard let self, let window, let configurationStore = self.configurationStore else {
                        return
                    }

                    let size = window.contentLayoutRect.size
                    configurationStore.updateMenuBarDashboardSize(
                        width: Double(size.width),
                        height: Double(size.height)
                    )
                }
            }
        }

        func configure(configurationStore: ProviderConfigurationStore) {
            guard let window else {
                return
            }

            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(
                width: DashboardPanelSize.minimumSize.width,
                height: DashboardPanelSize.minimumSize.height
            )

            if let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame {
                window.contentMaxSize = NSSize(
                    width: max(DashboardPanelSize.minimumSize.width, visibleFrame.width),
                    height: max(DashboardPanelSize.minimumSize.height, visibleFrame.height)
                )
            }

            guard restoredWindow !== window else {
                return
            }

            let savedSize = configurationStore.menuBarDashboardSize
            let maxSize = window.contentMaxSize
            window.setContentSize(NSSize(
                width: min(savedSize.width, maxSize.width),
                height: min(savedSize.height, maxSize.height)
            ))
            restoredWindow = window
        }

        func detach() {
            if let resizeObserver {
                NotificationCenter.default.removeObserver(resizeObserver)
            }
            resizeObserver = nil
            window = nil
            restoredWindow = nil
            configurationStore = nil
        }

        deinit {}
    }
}

private final class WindowProbeView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }

    deinit {}
}
