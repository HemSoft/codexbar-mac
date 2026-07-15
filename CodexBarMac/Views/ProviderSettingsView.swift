import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let accountID: String
    var onAccountsChanged: @MainActor () async -> Void = {}
    var onCredentialsChanged: @MainActor () async -> Void = {}

    @State private var configuration: ProviderAccountConfiguration
    @State private var secret = ""
    @State private var isSigningInWithCursor = false
    @State private var cursorAuthError: String?
    @State private var cursorSignInTask: Task<Void, Never>?
#if canImport(AuthenticationServices) && canImport(AppKit)
    @State private var cursorAuthPresenter = CursorWebAuthenticationPresenter()
#endif
    private let cursorAuthService = CursorWebAuthService()

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

                if providerID == .cursor {
                    cursorCredentialControls
                } else if configuration.requiresSecret {
                    SecureField(secretPlaceholder, text: $secret)
                        .textFieldStyle(.roundedBorder)

                    Button(configurationStore.hasSecret(for: configuration) ? "Update API Key" : "Save API Key") {
                        saveSecret()
                    }
                    .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if configurationStore.hasSecret(for: configuration), providerID != .cursor {
                    Button("Remove Saved Key", role: .destructive) {
                        removeSecret()
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
        .onDisappear {
            cursorSignInTask?.cancel()
#if canImport(AuthenticationServices) && canImport(AppKit)
            cursorAuthPresenter.finish()
#endif
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
    private var cursorCredentialControls: some View {
        Button {
            startCursorSignIn()
        } label: {
            if isSigningInWithCursor {
                ProgressView()
            } else {
                Text(
                    configurationStore.hasSecret(for: configuration)
                        ? "Switch Cursor Account"
                        : "Sign in with Cursor"
                )
            }
        }
        .disabled(isSigningInWithCursor)

        if configurationStore.hasSecret(for: configuration) {
            Button("Sign Out", role: .destructive) {
                signOutOfCursor()
            }
        }

        if let cursorAuthError {
            Text(cursorAuthError)
                .foregroundStyle(.red)
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
            [.codexAuthJSON]
        case .copilot:
            [.cliToken, .browserSession]
        case .openRouter, .openCodeZen:
            [.apiKey]
        case .claude:
            [.browserSession, .oauth]
        case .cursor:
            [.browserSession]
        }
    }

    private var secretPlaceholder: String {
        configurationStore.hasSecret(for: configuration) ? "Credential saved" : "Paste API key or token"
    }

    private var credentialGuidance: String {
        switch providerID {
        case .codex:
            "CodexBar reads Codex CLI credentials from ~/.codex/auth.json. Browser sign-in will be added in a later issue."
        case .copilot:
            "GitHub Copilot can use GitHub CLI credentials discovered from `gh auth status`, or a token saved in the Keychain."
        case .claude:
            "Claude Code OAuth credentials from the macOS Keychain or ~/.claude/.credentials.json are preferred when available. Browser sign-in remains the fallback."
        case .openRouter:
            "Store an OpenRouter management API key in the Keychain. Inference-only keys cannot read credit balance."
        case .openCodeZen:
            "Store an OpenCode ZEN API key in the Keychain."
        case .cursor:
            "Cursor can use the local Cursor app session from ~/Library/Application Support/Cursor/auth.json, or sign in through the browser."
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

    @MainActor
    private func startCursorSignIn() {
        guard cursorSignInTask == nil else {
            return
        }
        cursorSignInTask = Task { @MainActor in
            await signInWithCursor()
        }
    }

    @MainActor
    private func signInWithCursor() async {
        isSigningInWithCursor = true
        cursorAuthError = nil
        defer {
#if canImport(AuthenticationServices) && canImport(AppKit)
            cursorAuthPresenter.finish()
#endif
            cursorSignInTask = nil
            isSigningInWithCursor = false
        }

        do {
            let result = try await cursorAuthService.signIn { url in
#if canImport(AuthenticationServices) && canImport(AppKit)
                return cursorAuthPresenter.present(url: url) {
                    cursorSignInTask?.cancel()
                }
#else
                _ = url
                return false
#endif
            }
            guard let connectedConfiguration = configurationStore.connectCursorAccount(
                configuration,
                credential: result.storedCredential
            ) else {
                cursorAuthError = configurationStore.lastError
                return
            }
            configuration = connectedConfiguration
            secret = ""
            await onCredentialsChanged()
        } catch {
            cursorAuthError = Task.isCancelled
                ? "Cursor sign-in canceled. The existing account was not changed."
                : error.localizedDescription
        }
    }

    @MainActor
    private func signOutOfCursor() {
        cursorAuthError = nil
        guard let disconnectedConfiguration = configurationStore.disconnectCursorAccount(configuration) else {
            cursorAuthError = configurationStore.lastError
            return
        }
        configuration = disconnectedConfiguration
        Task {
            await onCredentialsChanged()
        }
    }
}
