import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var isConfirmingReset = false

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
            }
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

    private func resetAccounts() {
        for configuration in configurationStore.configurations {
            configurationStore.removeAccount(configuration)
        }

        Task {
            await model.handleAccountsChanged()
        }
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
        case .cursor:
            "cursorarrow.rays"
        }
    }
}
