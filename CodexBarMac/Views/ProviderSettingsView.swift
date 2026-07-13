import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let accountID: String
    var onAccountsChanged: @MainActor () async -> Void = {}
    var onCredentialsChanged: @MainActor () async -> Void = {}

    @State private var configuration: ProviderAccountConfiguration
    @State private var secret = ""

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        onAccountsChanged: @escaping @MainActor () async -> Void = {},
        onCredentialsChanged: @escaping @MainActor () async -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.accountID = accountID
        self.onAccountsChanged = onAccountsChanged
        self.onCredentialsChanged = onCredentialsChanged
        self._configuration = State(
            initialValue: configurationStore.configuration(accountID: accountID)
                ?? ProviderID(rawValue: accountID).map(ProviderAccountConfiguration.defaultConfiguration)
                ?? .defaultConfiguration(for: .codex)
        )
    }

    var body: some View {
        Form {
            Section("Account") {
                Toggle("Enabled", isOn: $configuration.isEnabled)

                TextField("Account label", text: $configuration.accountLabel)
                    .textFieldStyle(.roundedBorder)

                Picker("Auth method", selection: $configuration.authMethod) {
                    ForEach(availableAuthMethods) { method in
                        Text(method.displayName).tag(method)
                    }
                }
            }

            Section("Credentials") {
                Text(credentialGuidance)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                credentialStatusView

                if configuration.requiresSecret {
                    SecureField(secretPlaceholder, text: $secret)
                        .textFieldStyle(.roundedBorder)

                    Button(configurationStore.hasSecret(for: configuration) ? "Update API Key" : "Save API Key") {
                        saveSecret()
                    }
                    .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Remove Saved Key", role: .destructive) {
                            removeSecret()
                        }
                    }
                }
            }

            if let lastError = configurationStore.lastError {
                Section {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(configuration.providerID.displayName)
        .onAppear {
            configurationStore.refreshSecretAvailability(including: [configuration])
        }
        .onChange(of: configuration) { oldValue, newValue in
            guard configurationStore.update(newValue) else {
                configuration = oldValue
                return
            }

            let shouldRefresh = oldValue.isEnabled != newValue.isEnabled
                || oldValue.authMethod != newValue.authMethod
            guard shouldRefresh else {
                return
            }

            Task {
                await onAccountsChanged()
            }
        }
    }

    @ViewBuilder
    private var credentialStatusView: some View {
        switch configurationStore.credentialReadiness(for: configuration) {
        case .keychainSaved:
            Label("Credential saved in Keychain", systemImage: "key.fill")
                .foregroundStyle(.green)
        case .localCLIReady(let description):
            Label("Local credentials ready (\(description))", systemImage: "terminal.fill")
                .foregroundStyle(.green)
        case .missing:
            Label("No credentials configured yet", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var providerID: ProviderID {
        configuration.providerID
    }

    private var availableAuthMethods: [ProviderAuthMethod] {
        switch providerID {
        case .codex:
            [.codexAuthJSON, .browserSession]
        case .copilot:
            [.cliToken, .browserSession]
        case .openRouter, .openCodeZen:
            [.apiKey]
        case .claude, .cursor:
            [.browserSession, .oauth]
        }
    }

    private var secretPlaceholder: String {
        configurationStore.hasSecret(for: configuration) ? "Credential saved" : "Paste API key or token"
    }

    private var credentialGuidance: String {
        switch providerID {
        case .codex:
            "CodexBar reads Codex CLI credentials from ~/.codex/auth.json when auth.json is selected. Browser sign-in remains available as a fallback."
        case .copilot:
            "GitHub Copilot can use GitHub CLI credentials discovered from `gh auth status`, or a token saved in the Keychain."
        case .claude:
            "Claude Code OAuth credentials from the macOS Keychain or ~/.claude/.credentials.json are preferred when available. Browser sign-in remains the fallback."
        case .openRouter:
            "Store an OpenRouter API key in the Keychain."
        case .openCodeZen:
            "Store an OpenCode ZEN API key in the Keychain."
        case .cursor:
            "Cursor browser or local session auth will be added in issue #11."
        }
    }

    private func saveSecret() {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else {
            return
        }

        configurationStore.saveSecret(trimmedSecret, for: configuration)
        secret = ""

        Task {
            await onCredentialsChanged()
        }
    }

    private func removeSecret() {
        configurationStore.saveSecret("", for: configuration)
        secret = ""

        Task {
            await onCredentialsChanged()
        }
    }
}
