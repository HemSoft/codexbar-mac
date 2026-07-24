import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var isConfirmingReset = false
    @State private var alertPermissionMessage: String?
    @State private var alertAuthorizationGeneration = 0
    @State private var alertAuthorizationTask: Task<Void, Never>?
    @State private var newGroupName = ""

    private var configurationStore: ProviderConfigurationStore {
        model.configurationStore
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("General") {
                    Picker("Appearance", selection: appearanceBinding) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }

                    Picker("Auto Refresh", selection: autoRefreshIntervalBinding) {
                        ForEach(AutoRefreshInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }

                    Picker("Dashboard Order", selection: dashboardOrderingModeBinding) {
                        ForEach(DashboardOrderingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle("Launch at Login", isOn: launchAtLoginBinding)

                    if model.launchAtLoginManager.requiresApproval {
                        Text("Approve CodexBar in System Settings > General > Login Items to finish enabling launch at login.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if let launchError = model.launchAtLoginManager.lastError {
                        Text(launchError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section("Alerts") {
                    Toggle("Usage Alerts", isOn: usageAlertsEnabledBinding)

                    Stepper(value: usageAlertUsagePercentBinding, in: 50...100, step: 5) {
                        Text("Usage at \(Int((configurationStore.usageAlertSettings.usageThreshold * 100).rounded()))%")
                    }
                    .disabled(!configurationStore.usageAlertSettings.isEnabled)

                    Stepper(value: usageAlertBalanceBinding, in: 1...100, step: 1) {
                        Text("Balance below \(formattedBalanceThreshold)")
                    }
                    .disabled(!configurationStore.usageAlertSettings.isEnabled)

                    Toggle("Warning and Critical Alerts", isOn: usageAlertSeverityBinding)
                        .disabled(!configurationStore.usageAlertSettings.isEnabled)

                    if let alertPermissionMessage {
                        Text(alertPermissionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Groups") {
                    if configurationStore.groups.isEmpty {
                        Text("No groups")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(configurationStore.groups) { group in
                        GroupSettingsRow(
                            group: group,
                            onRename: { name in
                                var updated = group
                                updated.name = name
                                return configurationStore.updateGroup(updated)
                            },
                            onDelete: {
                                configurationStore.removeGroup(group)
                            }
                        )
                    }

                    HStack {
                        TextField("New group", text: $newGroupName)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addGroup)

                        Button(action: addGroup) {
                            Label("Add Group", systemImage: "plus.circle")
                        }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    Text("Deleting a group moves its accounts to Ungrouped.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Accounts") {
                    if configurationStore.configurations.isEmpty {
                        Text("No accounts")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(configurationStore.configurations) { configuration in
                        HStack {
                            Toggle(
                                "Enabled",
                                isOn: enabledBinding(for: configuration)
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .accessibilityLabel("Enabled \(configuration.displayName)")

                            NavigationLink {
                                ProviderSettingsView(
                                    configurationStore: configurationStore,
                                    accountID: configuration.id,
                                    onAccountsChanged: {
                                        await model.handleAccountsChanged()
                                    },
                                    onCredentialsChanged: {
                                        await model.handleAccountsChanged()
                                    },
                                    onAccountRefresh: { configuration in
                                        await model.refreshAccount(configuration)
                                    }
                                )
                            } label: {
                                ProviderSettingsRow(
                                    configuration: configuration,
                                    readiness: configurationStore.credentialReadiness(for: configuration)
                                )
                            }

                            Spacer()

                            Button(role: .destructive) {
                                configurationStore.removeAccount(configuration)
                                Task {
                                    await model.handleAccountsChanged()
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove account")
                        }
                    }

                    Menu {
                        ForEach(ProviderID.allCases) { providerID in
                            Button {
                                _ = configurationStore.addAccount(for: providerID)
                                Task {
                                    await model.handleAccountsChanged()
                                }
                            } label: {
                                Label(providerID.displayName, systemImage: providerID.settingsIconName)
                            }
                        }
                    } label: {
                        Label("Add Account", systemImage: "plus.circle")
                    }
                }

                Section {
                    Button("Reset Accounts", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .disabled(configurationStore.configurations.isEmpty)
                }

                if let lastError = configurationStore.lastError {
                    Section {
                        Text(lastError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("CodexBar")
            .confirmationDialog(
                "Reset all accounts?",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset Accounts", role: .destructive) {
                    resetAccounts()
                }
            } message: {
                Text("This removes account entries and saved provider credentials from this device.")
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onAppear {
            model.launchAtLoginManager.refreshFromSystem()
            Task {
                await model.discoverLocalCredentials()
                await syncUsageAlertAuthorizationState()
            }
        }
        .onDisappear {
            alertAuthorizationTask?.cancel()
            alertAuthorizationTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.launchAtLoginManager.refreshFromSystem()
        }
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { configurationStore.appAppearance },
            set: { configurationStore.updateAppAppearance($0) }
        )
    }

    private var autoRefreshIntervalBinding: Binding<AutoRefreshInterval> {
        Binding(
            get: { configurationStore.autoRefreshInterval },
            set: { newValue in
                configurationStore.updateAutoRefreshInterval(newValue)
                model.updateAutoRefresh()
            }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginManager.isToggleOn },
            set: { model.launchAtLoginManager.setEnabled($0) }
        )
    }

    private var usageAlertsEnabledBinding: Binding<Bool> {
        Binding(
            get: { configurationStore.usageAlertSettings.isEnabled },
            set: { isEnabled in
                if isEnabled {
                    requestUsageAlertAuthorization()
                } else {
                    alertAuthorizationGeneration += 1
                    alertAuthorizationTask?.cancel()
                    alertAuthorizationTask = nil
                    configurationStore.updateUsageAlertsEnabled(false)
                    alertPermissionMessage = nil
                }
            }
        )
    }

    private var usageAlertUsagePercentBinding: Binding<Double> {
        Binding(
            get: { configurationStore.usageAlertSettings.usageThreshold * 100 },
            set: { configurationStore.updateUsageAlertUsageThreshold($0 / 100) }
        )
    }

    private var dashboardOrderingModeBinding: Binding<DashboardOrderingMode> {
        Binding(
            get: { configurationStore.dashboardOrderingMode },
            set: { configurationStore.updateDashboardOrderingMode($0) }
        )
    }

    private var usageAlertBalanceBinding: Binding<Double> {
        Binding(
            get: { configurationStore.usageAlertSettings.balanceThreshold },
            set: { configurationStore.updateUsageAlertBalanceThreshold($0) }
        )
    }

    private var usageAlertSeverityBinding: Binding<Bool> {
        Binding(
            get: { configurationStore.usageAlertSettings.includesSeverityAlerts },
            set: { configurationStore.updateUsageAlertIncludesSeverityAlerts($0) }
        )
    }

    private var formattedBalanceThreshold: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: configurationStore.usageAlertSettings.balanceThreshold))
            ?? "$\(Int(configurationStore.usageAlertSettings.balanceThreshold.rounded()))"
    }

    @MainActor
    private func syncUsageAlertAuthorizationState() async {
        alertAuthorizationGeneration += 1
        alertAuthorizationTask?.cancel()
        alertAuthorizationTask = nil

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            alertPermissionMessage = nil
        case .denied:
            if configurationStore.usageAlertSettings.isEnabled {
                configurationStore.updateUsageAlertsEnabled(false)
            }
            alertPermissionMessage = "Notifications are disabled for CodexBar."
        case .notDetermined:
            if configurationStore.usageAlertSettings.isEnabled {
                let granted = await model.requestUsageAlertAuthorization()
                if !granted {
                    configurationStore.updateUsageAlertsEnabled(false)
                    alertPermissionMessage = "Notifications are disabled for CodexBar."
                }
            }
        @unknown default:
            break
        }
    }

    private func requestUsageAlertAuthorization() {
        alertAuthorizationGeneration += 1
        let generation = alertAuthorizationGeneration
        alertAuthorizationTask?.cancel()
        alertAuthorizationTask = Task {
            let granted = await model.requestUsageAlertAuthorization()
            guard !Task.isCancelled, generation == alertAuthorizationGeneration else {
                return
            }

            configurationStore.updateUsageAlertsEnabled(granted)
            alertPermissionMessage = granted ? nil : "Notifications are disabled for CodexBar."
            alertAuthorizationTask = nil
        }
    }

    private func resetAccounts() {
        if configurationStore.removeAccounts(configurationStore.configurations) {
            Task {
                await model.handleAccountsChanged()
            }
        }
    }

    private func addGroup() {
        guard configurationStore.addGroup(named: newGroupName) != nil else {
            return
        }

        newGroupName = ""
    }

    private func enabledBinding(
        for configuration: ProviderAccountConfiguration
    ) -> Binding<Bool> {
        Binding(
            get: {
                configurationStore.configuration(accountID: configuration.id)?.isEnabled ?? configuration.isEnabled
            },
            set: { isEnabled in
                var updated = configurationStore.configuration(accountID: configuration.id) ?? configuration
                updated.isEnabled = isEnabled
                guard configurationStore.update(updated) else {
                    return
                }

                Task {
                    await model.handleAccountsChanged()
                }
            }
        )
    }
}

private struct GroupSettingsRow: View {
    let group: ProviderAccountGroup
    let onRename: (String) -> Bool
    let onDelete: () -> Void

    @State private var name: String

    init(
        group: ProviderAccountGroup,
        onRename: @escaping (String) -> Bool,
        onDelete: @escaping () -> Void
    ) {
        self.group = group
        self.onRename = onRename
        self.onDelete = onDelete
        self._name = State(initialValue: group.name)
    }

    var body: some View {
        HStack {
            TextField("Group name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(renameGroup)

            Button("Rename", action: renameGroup)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines) == group.name)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete group")
        }
        .onChange(of: group.name) { _, newValue in
            name = newValue
        }
    }

    private func renameGroup() {
        if !onRename(name) {
            name = group.name
        }
    }
}

private struct ProviderSettingsRow: View {
    let configuration: ProviderAccountConfiguration
    let readiness: CredentialReadiness

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusTint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.displayName)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        if !configuration.isEnabled {
            return "pause.circle"
        }

        switch readiness {
        case .keychainSaved, .localCLIReady:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .missing:
            return "exclamationmark.circle"
        }
    }

    private var statusTint: Color {
        if !configuration.isEnabled {
            return .secondary
        }

        switch readiness {
        case .keychainSaved, .localCLIReady:
            return .green
        case .error:
            return .red
        case .missing:
            return .orange
        }
    }

    private var statusText: String {
        if !configuration.isEnabled {
            return "Disabled"
        }

        switch readiness {
        case .keychainSaved:
            return "Keychain credential saved"
        case .localCLIReady(let description):
            return "Local credentials ready (\(description))"
        case .error(let description):
            return description
        case .missing:
            return "Needs credentials"
        }
    }
}

private extension ProviderID {
    var settingsIconName: String {
        switch self {
        case .codex:
            "sparkles"
        case .copilot:
            "terminal"
        case .claude:
            "brain.head.profile"
        case .openRouter:
            "arrow.triangle.branch"
        case .openCodeZen:
            "cube"
        case .moonshot:
            "moon.stars"
        case .cursor:
            "cursorarrow.rays"
        case .gemini:
            "wand.and.stars"
        }
    }
}
