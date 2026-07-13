import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let accountID: String
    var onAccountsChanged: @MainActor () async -> Void = {}

    @State private var configuration: ProviderAccountConfiguration

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        onAccountsChanged: @escaping @MainActor () async -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.accountID = accountID
        self.onAccountsChanged = onAccountsChanged
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

                if configuration.requiresSecret {
                    SecureField("API key or token", text: .constant(""))
                        .disabled(true)

                    Text("Credential entry will be wired up in issue #6.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

    private var credentialGuidance: String {
        switch providerID {
        case .codex:
            "CodexBar will read Codex CLI credentials from ~/.codex/auth.json when the Codex provider lands in issue #7."
        case .copilot:
            "GitHub Copilot will use GitHub CLI credentials when the Copilot provider lands in issue #9."
        case .claude:
            "Claude Code local OAuth credentials will be preferred over browser sign-in when issue #8 lands."
        case .openRouter:
            "Store an OpenRouter API key in the Keychain when issue #10 lands."
        case .openCodeZen:
            "Store an OpenCode ZEN API key in the Keychain when issue #12 lands."
        case .cursor:
            "Cursor browser or local session auth will be added in issue #11."
        }
    }
}
