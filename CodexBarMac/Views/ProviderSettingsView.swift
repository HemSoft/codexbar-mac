import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let accountID: String
    var onAccountsChanged: @MainActor () async -> Void = {}
    var onCredentialsChanged: @MainActor () async -> Void = {}
    var onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }

    @State private var configuration: ProviderAccountConfiguration
    @State private var secret = ""
    @State private var isSigningInWithCodex = false
    @State private var codexAuthError: String?
    @State private var codexSignInTask: Task<Void, Never>?
    @State private var isSigningInWithClaude = false
    @State private var claudeAuthError: String?
    @State private var claudeAuthDiagnostic: String?
    @State private var claudeSignInTask: Task<Void, Never>?
    @State private var isSigningInWithCopilot = false
    @State private var copilotAuthError: String?
    @State private var copilotSignInTask: Task<Void, Never>?
    @State private var isSigningInWithCursor = false
    @State private var cursorAuthError: String?
    @State private var cursorSignInTask: Task<Void, Never>?
    @State private var isRefreshingOpenCode = false
    @State private var openCodeCredentialMessage: String?
    @State private var copilotAllotmentText = ""
#if canImport(AuthenticationServices) && canImport(AppKit)
    @State private var webAuthPresenter = ProviderWebAuthenticationPresenter()
#endif
    private let codexAuthService = CodexWebAuthService()
    private let claudeAuthService = ClaudeWebAuthService()
    private let copilotAuthService = CopilotWebAuthService()
    private let copilotUsageProvider = CopilotUsageProvider()
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
                Toggle("Show History", isOn: $configuration.showsHistory)

                TextField("Account label", text: $configuration.accountLabel)
                    .textFieldStyle(.roundedBorder)

                Picker("Group", selection: $configuration.groupID) {
                    Text(ProviderAccountGroup.ungroupedDisplayName).tag(Optional<String>.none)
                    ForEach(configurationStore.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }

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

                if providerID == .codex {
                    codexCredentialControls
                } else if providerID == .claude {
                    claudeCredentialControls
                } else if providerID == .copilot {
                    copilotCredentialControls
                } else if providerID == .cursor {
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

                if configurationStore.hasSecret(for: configuration),
                   ![.codex, .claude, .copilot, .cursor, .openCodeZen].contains(providerID) {
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
            codexSignInTask?.cancel()
            claudeSignInTask?.cancel()
            copilotSignInTask?.cancel()
            cursorSignInTask?.cancel()
#if canImport(AuthenticationServices) && canImport(AppKit)
            webAuthPresenter.finish()
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
    private var codexCredentialControls: some View {
        Button {
            startCodexSignIn()
        } label: {
            if isSigningInWithCodex {
                ProgressView()
            } else {
                Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with ChatGPT")
            }
        }
        .disabled(isSigningInWithCodex)

        if configurationStore.hasSecret(for: configuration) {
            Button("Remove Browser Sign-In", role: .destructive) {
                removeBrowserCredential()
            }
        }

        if let codexAuthError {
            Text(codexAuthError)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var claudeCredentialControls: some View {
        Button {
            startClaudeSignIn()
        } label: {
            if isSigningInWithClaude {
                ProgressView()
            } else {
                Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with Claude")
            }
        }
        .disabled(isSigningInWithClaude)

        if configurationStore.hasSecret(for: configuration) {
            Button("Remove Browser Sign-In", role: .destructive) {
                removeBrowserCredential()
            }
        }

        if let claudeAuthDiagnostic {
            Text(claudeAuthDiagnostic)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if let claudeAuthError {
            Text(claudeAuthError)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var copilotCredentialControls: some View {
        Button {
            startCopilotSignIn()
        } label: {
            if isSigningInWithCopilot {
                ProgressView()
            } else {
                Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with GitHub")
            }
        }
        .disabled(isSigningInWithCopilot)

        if configuration.authMethod == .cliToken {
            SecureField(secretPlaceholder, text: $secret)
                .textFieldStyle(.roundedBorder)

            Button(configurationStore.hasSecret(for: configuration) ? "Update Token" : "Save Token") {
                saveSecret()
            }
            .disabled(
                isSigningInWithCopilot
                    || secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }

        if configurationStore.hasSecret(for: configuration) {
            Button("Remove Saved Credential", role: .destructive) {
                removeCopilotCredential()
            }
        }

        if let copilotAuthError {
            Text(copilotAuthError)
                .foregroundStyle(.red)
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
            [.codexAuthJSON, .browserSession]
        case .copilot:
            [.cliToken, .browserSession]
        case .openRouter, .openCodeZen, .moonshot:
            [.apiKey]
        case .claude:
            [.oauth, .browserSession]
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
            "CodexBar prefers Codex CLI credentials from ~/.codex/auth.json. If they are unavailable, sign in with ChatGPT in the browser; CodexBar stores those tokens in Keychain."
        case .copilot:
            if configuration.copilotAccountScope == .organization {
                "Enter the GitHub organization (and optional enterprise) for Copilot AI-credit billing. CodexBar prefers GitHub CLI credentials with org billing access; browser sign-in is available as a fallback."
            } else {
                "CodexBar prefers GitHub CLI credentials discovered from `gh auth status`. You can also sign in with GitHub in the browser; CodexBar stores those tokens in Keychain."
            }
        case .claude:
            "CodexBar prefers Claude Code OAuth credentials from the macOS Keychain or ~/.claude/.credentials.json. If they are unavailable, sign in with Claude in the browser; CodexBar stores those tokens in its Keychain entry."
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
        if let allotment = configuration.copilotTotalAllotment, allotment > 0, allotment.isFinite {
            copilotAllotmentText = String(format: "%.0f", allotment.rounded())
        } else {
            copilotAllotmentText = ""
        }
    }

    private static func parsedCopilotAllotment(from text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let value = Double(trimmed), value > 0, value.isFinite else {
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

    private func removeBrowserCredential() {
        configurationStore.saveSecret("", for: configuration)
        codexAuthError = configurationStore.lastError
        claudeAuthError = configurationStore.lastError
        claudeAuthDiagnostic = nil

        Task {
            await onCredentialsChanged()
        }
    }

    private func removeCopilotCredential() {
        configurationStore.saveSecret("", for: configuration)
        copilotAuthError = configurationStore.lastError
        secret = ""

        Task {
            await onCredentialsChanged()
        }
    }

    @MainActor
    private func startCodexSignIn() {
        guard codexSignInTask == nil else {
            return
        }
        codexSignInTask = Task { @MainActor in
            await signInWithCodex()
        }
    }

    @MainActor
    private func signInWithCodex() async {
        isSigningInWithCodex = true
        codexAuthError = nil
        defer {
#if canImport(AuthenticationServices) && canImport(AppKit)
            webAuthPresenter.finish()
#endif
            codexSignInTask = nil
            isSigningInWithCodex = false
        }

        do {
            let result = try await codexAuthService.signIn { url in
#if canImport(AuthenticationServices) && canImport(AppKit)
                return webAuthPresenter.present(url: url) {
                    codexSignInTask?.cancel()
                }
#else
                _ = url
                return false
#endif
            }
            var updated = configuration
            updated.authMethod = .browserSession
            guard configurationStore.update(updated) else {
                codexAuthError = configurationStore.lastError
                return
            }
            configuration = updated
            configurationStore.saveSecret(result.storedCredential, for: updated)
            guard configurationStore.lastError == nil else {
                codexAuthError = configurationStore.lastError
                return
            }
            secret = ""
            await onCredentialsChanged()
        } catch {
            codexAuthError = Task.isCancelled
                ? "ChatGPT sign-in canceled. The existing account was not changed."
                : error.localizedDescription
        }
    }

    @MainActor
    private func startClaudeSignIn() {
        guard claudeSignInTask == nil else {
            return
        }
        claudeSignInTask = Task { @MainActor in
            await signInWithClaude()
        }
    }

    @MainActor
    private func signInWithClaude() async {
        isSigningInWithClaude = true
        claudeAuthError = nil
        claudeAuthDiagnostic = nil
        defer {
#if canImport(AuthenticationServices) && canImport(AppKit)
            webAuthPresenter.finish()
#endif
            claudeSignInTask = nil
            isSigningInWithClaude = false
        }

        do {
            let result = try await claudeAuthService.signIn(
                presentAuthorizationURL: { url in
#if canImport(AuthenticationServices) && canImport(AppKit)
                    return webAuthPresenter.present(url: url) {
                        claudeSignInTask?.cancel()
                    }
#else
                    _ = url
                    return false
#endif
                },
                reportStage: { message in
                    claudeAuthDiagnostic = message
                }
            )
            var updated = configuration
            updated.authMethod = .browserSession
            guard configurationStore.update(updated) else {
                claudeAuthError = configurationStore.lastError
                return
            }
            configuration = updated
            configurationStore.saveSecret(result.storedCredential, for: updated)
            guard configurationStore.lastError == nil else {
                claudeAuthError = configurationStore.lastError
                claudeAuthDiagnostic = "Claude sign-in failed."
                return
            }
            secret = ""
            claudeAuthDiagnostic = "Claude sign-in complete."
            await onCredentialsChanged()
        } catch {
            claudeAuthError = Task.isCancelled
                ? "Claude sign-in canceled. The existing account was not changed."
                : error.localizedDescription
            if claudeAuthDiagnostic == nil {
                claudeAuthDiagnostic = "Claude sign-in failed."
            }
        }
    }

    @MainActor
    private func startCopilotSignIn() {
        guard copilotSignInTask == nil else {
            return
        }
        copilotSignInTask = Task { @MainActor in
            await signInWithCopilot()
        }
    }

    @MainActor
    private func signInWithCopilot() async {
        isSigningInWithCopilot = true
        copilotAuthError = nil
        defer {
#if canImport(AuthenticationServices) && canImport(AppKit)
            webAuthPresenter.finish()
#endif
            copilotSignInTask = nil
            isSigningInWithCopilot = false
        }

        do {
            let result = try await copilotAuthService.signIn { url in
#if canImport(AuthenticationServices) && canImport(AppKit)
                return webAuthPresenter.present(url: url) {
                    copilotSignInTask?.cancel()
                }
#else
                _ = url
                return false
#endif
            }
            let username = try await copilotUsageProvider.fetchUsername(accessToken: result.accessToken)
            guard let username, !username.isEmpty else {
                copilotAuthError = "GitHub sign-in completed, but the token could not be verified for Copilot access."
                return
            }

            var updated = configuration
            updated.authMethod = .browserSession
            updated.githubCLIUsername = username
            if updated.copilotAccountScope == .personal {
                updated.accountLabel = username
            } else if updated.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.accountLabel = updated.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard configurationStore.update(updated) else {
                copilotAuthError = configurationStore.lastError
                return
            }
            configuration = updated
            configurationStore.saveSecret(result.storedCredential(username: username), for: updated)
            guard configurationStore.lastError == nil else {
                copilotAuthError = configurationStore.lastError
                return
            }
            secret = ""
            await onCredentialsChanged()
        } catch {
            copilotAuthError = Task.isCancelled
                ? "GitHub sign-in canceled. The existing account was not changed."
                : error.localizedDescription
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
            webAuthPresenter.finish()
#endif
            cursorSignInTask = nil
            isSigningInWithCursor = false
        }

        do {
            let result = try await cursorAuthService.signIn { url in
#if canImport(AuthenticationServices) && canImport(AppKit)
                return webAuthPresenter.present(url: url) {
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
