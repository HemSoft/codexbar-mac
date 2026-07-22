import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let accountID: String
    var onAccountsChanged: @MainActor () async -> Void = {}
    var onCredentialsChanged: @MainActor () async -> Void = {}
    var onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }

    @State private var configuration: ProviderAccountConfiguration
    @State private var secret = ""
    @State private var isSigningInWithCursor = false
    @State private var cursorAuthError: String?
    @State private var cursorSignInTask: Task<Void, Never>?
    @State private var isRefreshingOpenCode = false
    @State private var openCodeCredentialMessage: String?
    @State private var copilotAllotmentText = ""
#if canImport(AuthenticationServices) && canImport(AppKit)
    @State private var cursorAuthPresenter = CursorWebAuthenticationPresenter()
#endif
    private let cursorAuthService = CursorWebAuthService()

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        onAccountsChanged: @escaping @MainActor () async -> Void = {},
        onCredentialsChanged: @escaping @MainActor () async -> Void = {},
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }
    ) {
        self.configurationStore = configurationStore
        self.accountID = accountID
        self.onAccountsChanged = onAccountsChanged
        self.onCredentialsChanged = onCredentialsChanged
        self.onAccountRefresh = onAccountRefresh
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

                if providerID == .openCodeZen {
                    TextField("Workspace ID", text: $configuration.openCodeWorkspaceId)
                        .textFieldStyle(.roundedBorder)
                }

                if providerID == .copilot {
                    Picker("Account type", selection: $configuration.copilotAccountScope) {
                        ForEach(CopilotAccountScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }

                    if configuration.copilotAccountScope == .organization {
                        TextField("Organization", text: $configuration.githubOrganization)
                            .textFieldStyle(.roundedBorder)
                        TextField("Enterprise (optional)", text: $configuration.githubEnterprise)
                            .textFieldStyle(.roundedBorder)
                        TextField("Total allotment (optional)", text: $copilotAllotmentText)
                            .textFieldStyle(.roundedBorder)
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
                } else if providerID == .openCodeZen {
                    openCodeCredentialControls
                } else if configuration.requiresSecret {
                    SecureField(secretPlaceholder, text: $secret)
                        .textFieldStyle(.roundedBorder)

                    Button(configurationStore.hasSecret(for: configuration) ? "Update API Key" : "Save API Key") {
                        saveSecret()
                    }
                    .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if configurationStore.hasSecret(for: configuration), providerID != .cursor, providerID != .openCodeZen {
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
            syncCopilotAllotmentText()
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
                syncCopilotAllotmentText()
                return
            }

            let shouldRefresh = oldValue.isEnabled != newValue.isEnabled
                || oldValue.authMethod != newValue.authMethod
                || oldValue.copilotAccountScope != newValue.copilotAccountScope
                || oldValue.githubOrganization != newValue.githubOrganization
                || oldValue.githubEnterprise != newValue.githubEnterprise
                || oldValue.copilotTotalAllotment != newValue.copilotTotalAllotment
            guard shouldRefresh else {
                return
            }

            Task {
                await onAccountsChanged()
            }
        }
        .onChange(of: copilotAllotmentText) { _, newValue in
            let parsed = Self.parsedCopilotAllotment(from: newValue)
            guard configuration.copilotTotalAllotment != parsed else {
                return
            }
            configuration.copilotTotalAllotment = parsed
        }
    }

    @ViewBuilder
    private var openCodeCredentialControls: some View {
        SecureField(secretPlaceholder, text: $secret)
            .textFieldStyle(.roundedBorder)

        Button(configurationStore.hasSecret(for: configuration) ? "Update and Refresh" : "Save and Refresh") {
            saveOpenCodeCredential()
        }
        .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        if configurationStore.hasSecret(for: configuration) {
            Button {
                Task {
                    await refreshOpenCode()
                }
            } label: {
                if isRefreshingOpenCode {
                    ProgressView()
                } else {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isRefreshingOpenCode)
        }

        if configurationStore.hasSecret(for: configuration) {
            Button("Remove Saved Credential", role: .destructive) {
                configurationStore.saveSecret("", for: configuration)
                openCodeCredentialMessage = "OpenCode credential removed."
                Task {
                    await onCredentialsChanged()
                }
            }
        }

        if let openCodeCredentialMessage {
            Text(openCodeCredentialMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
        case .openRouter, .openCodeZen, .moonshot:
            [.apiKey]
        case .claude:
            [.browserSession, .oauth]
        case .cursor:
            [.browserSession]
        case .gemini:
            [.oauth]
        }
    }

    private var secretPlaceholder: String {
        if providerID == .openCodeZen {
            return configurationStore.hasSecret(for: configuration)
                ? "OpenCode dashboard auth value saved"
                : "Paste OpenCode dashboard auth value"
        }

        return configurationStore.hasSecret(for: configuration) ? "Credential saved" : "Paste API key or token"
    }

    private var credentialGuidance: String {
        switch providerID {
        case .codex:
            "CodexBar reads Codex CLI credentials from ~/.codex/auth.json. Browser sign-in will be added in a later issue."
        case .copilot:
            if configuration.copilotAccountScope == .organization {
                "Enter the GitHub organization (and optional enterprise) for Copilot AI-credit billing. Prefer GitHub CLI credentials with org billing access, or save a token with the required org permissions."
            } else {
                "GitHub Copilot can use GitHub CLI credentials discovered from `gh auth status`, or a token saved in the Keychain."
            }
        case .claude:
            "Claude Code OAuth credentials from the macOS Keychain or ~/.claude/.credentials.json are preferred when available. Browser sign-in remains the fallback."
        case .openRouter:
            "Store an OpenRouter management API key in the Keychain. Inference-only keys cannot read credit balance."
        case .openCodeZen:
            "Enter the OpenCode workspace ID and dashboard auth value. You can paste the Windows settings JSON or OPENCODE_GO_AUTH_COOKIE value."
        case .moonshot:
            "Store a Moonshot (Kimi) API key from platform.kimi.ai in the Keychain. Keys from platform.kimi.com are separate and will not work with this balance endpoint."
        case .cursor:
            "Cursor can use the local Cursor app session from ~/Library/Application Support/Cursor/auth.json, or sign in through the browser."
        case .gemini:
            "Gemini reads Gemini CLI OAuth credentials from ~/.gemini/oauth_creds.json after you run 'gemini' and complete login. This matches the Windows app and targets Code Assist / enterprise CLI sessions; individual Google AI Pro/Ultra OAuth via the CLI may no longer be supported. Token refresh uses OAuth client credentials from that file, the token audience, or CODEXBAR_GOOGLE_CLIENT_ID / CODEXBAR_GOOGLE_CLIENT_SECRET."
        }
    }

    private func syncCopilotAllotmentText() {
        if let allotment = configuration.copilotTotalAllotment, allotment > 0 {
            copilotAllotmentText = String(Int(allotment.rounded()))
        } else {
            copilotAllotmentText = ""
        }
    }

    private static func parsedCopilotAllotment(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 0 else {
            return nil
        }
        return value
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
    private func saveOpenCodeCredential() {
        guard configurationStore.update(configuration) else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }

        configurationStore.saveSecret(secret, for: configuration)
        guard configurationStore.lastError == nil else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }

        secret = ""
        let workspaceConfigured = !configuration.openCodeWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        openCodeCredentialMessage = workspaceConfigured
            ? "OpenCode dashboard auth value saved. Refreshing..."
            : "OpenCode dashboard auth value saved. Enter the workspace ID, then refresh."
        guard workspaceConfigured else {
            return
        }

        Task {
            await refreshOpenCode()
        }
    }

    @MainActor
    private func refreshOpenCode() async {
        guard !isRefreshingOpenCode else {
            return
        }

        isRefreshingOpenCode = true
        openCodeCredentialMessage = "Refreshing OpenCode ZEN..."
        defer {
            isRefreshingOpenCode = false
        }

        guard let result = await onAccountRefresh(configuration) else {
            openCodeCredentialMessage = "Refresh finished. Check the dashboard."
            await onCredentialsChanged()
            return
        }

        if let balance = result.creditsRemaining {
            let formatted = Self.openCodeBalanceFormatter.string(from: NSNumber(value: balance)) ?? "$\(balance)"
            openCodeCredentialMessage = "OpenCode ZEN balance refreshed: \(formatted)"
        } else {
            openCodeCredentialMessage = result.subtitle
        }

        await onCredentialsChanged()
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

    private static let openCodeBalanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
