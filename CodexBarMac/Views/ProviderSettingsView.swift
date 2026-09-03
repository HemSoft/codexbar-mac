import SwiftUI

struct DashboardMetricOption: Identifiable, Equatable {
    let id: String
    let label: String
}

@MainActor
enum CredentialMutationFlow {
    static func canSaveOpenCodeSettings(
        enteredCredential: String,
        hasSavedCredential: Bool,
        hasStagedSettings: Bool
    ) -> Bool {
        !enteredCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || hasSavedCredential
            || hasStagedSettings
    }

    static func replacementCredential(
        enteredCredential: String,
        savedCredential: String?
    ) -> String? {
        if !enteredCredential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return enteredCredential
        }

        guard let savedCredential, !savedCredential.isEmpty else {
            return nil
        }
        return savedCredential
    }

    static func configurationForAutomaticPersistence(
        _ editedConfiguration: ProviderAccountConfiguration,
        persistedConfiguration: ProviderAccountConfiguration?
    ) -> ProviderAccountConfiguration {
        guard
            editedConfiguration.providerID == .openCodeZen,
            let persistedConfiguration,
            persistedConfiguration.id == editedConfiguration.id
        else {
            return editedConfiguration
        }

        var automaticallyPersisted = editedConfiguration
        automaticallyPersisted.isEnabled = persistedConfiguration.isEnabled
        automaticallyPersisted.accountLabel = persistedConfiguration.accountLabel
        automaticallyPersisted.authMethod = persistedConfiguration.authMethod
        automaticallyPersisted.openCodeWorkspaceId = persistedConfiguration.openCodeWorkspaceId
        return automaticallyPersisted
    }

    @discardableResult
    static func perform(
        secret: String,
        for configuration: ProviderAccountConfiguration,
        using configurationStore: ProviderConfigurationStore,
        onFailure: (String?) -> Void = { _ in },
        onSuccess: () -> Void
    ) -> Bool {
        guard configurationStore.saveSecret(secret, for: configuration) else {
            onFailure(configurationStore.lastError)
            return false
        }

        onSuccess()
        return true
    }
}

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let accountID: String
    let initialUsageResult: ProviderUsageResult?
    var onAccountsInvalidated: @MainActor () -> Void = {}
    var onAccountRefreshRequested: @MainActor () async -> Void = {}
    var onCredentialInvalidated: @MainActor () -> Void = {}
    var onCredentialRefreshRequested: @MainActor () async -> Void = {}
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
    @State private var usageResult: ProviderUsageResult?
    @State private var isRefreshingMetrics = false
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
        initialUsageResult: ProviderUsageResult? = nil,
        onAccountsInvalidated: @escaping @MainActor () -> Void = {},
        onAccountRefreshRequested: @escaping @MainActor () async -> Void = {},
        onCredentialInvalidated: @escaping @MainActor () -> Void = {},
        onCredentialRefreshRequested: @escaping @MainActor () async -> Void = {},
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }
    ) {
        self.configurationStore = configurationStore
        self.accountID = accountID
        self.initialUsageResult = initialUsageResult
        self.onAccountsInvalidated = onAccountsInvalidated
        self.onAccountRefreshRequested = onAccountRefreshRequested
        self.onCredentialInvalidated = onCredentialInvalidated
        self.onCredentialRefreshRequested = onCredentialRefreshRequested
        self.onAccountRefresh = onAccountRefresh
        self._configuration = State(
            initialValue: configurationStore.configuration(accountID: accountID)
                ?? ProviderID(rawValue: accountID).map(ProviderAccountConfiguration.defaultConfiguration)
                ?? .defaultConfiguration(for: .codex)
        )
        self._usageResult = State(initialValue: initialUsageResult)
    }

    var body: some View {
        Form {
            Section("Account") {
                Toggle("Enabled", isOn: $configuration.isEnabled)
                Toggle("Show History", isOn: $configuration.showsHistory)
                if providerID == .cursor {
                    Toggle("Show Grok Bot weekly", isOn: $configuration.showsCursorGrokBotWeekly)
                }

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

            Section("Metrics") {
                if let metricsRefreshFailureMessage {
                    Text(metricsRefreshFailureMessage)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("account-metrics-refresh-error")
                }

                if dashboardMetrics.isEmpty, metricsRefreshFailureMessage == nil {
                    Text(metricsEmptyStateMessage)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("account-metrics-empty-state")
                } else {
                    ForEach(dashboardMetrics) { metric in
                        Toggle(
                            metric.label,
                            isOn: Binding(
                                get: { configuration.isDashboardMetricVisible(stableKey: metric.id) },
                                set: { setMetricVisibility($0, stableKey: metric.id) }
                            )
                        )
                        .accessibilityLabel(
                            Self.metricAccessibilityLabel(
                                accountName: configuration.displayName,
                                metricName: metric.label
                            )
                        )
                        .accessibilityIdentifier("account-metric-visibility-\(metric.id)")
                    }
                }

                Button {
                    refreshMetrics()
                } label: {
                    if isRefreshingMetrics {
                        ProgressView()
                    } else {
                        Label("Refresh Metrics", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshingMetrics || !configuration.isEnabled)
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
        .onChange(of: initialUsageResult) { _, newValue in
            usageResult = newValue
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
            let persistedConfiguration = configurationStore.configuration(accountID: accountID)
            let automaticallyPersisted = CredentialMutationFlow.configurationForAutomaticPersistence(
                newValue,
                persistedConfiguration: persistedConfiguration
            )
            guard configurationStore.update(automaticallyPersisted) else {
                configuration = oldValue
                syncCopilotAllotmentText()
                return
            }

            let previousPersisted = persistedConfiguration ?? oldValue
            let shouldRefresh = previousPersisted.isEnabled != automaticallyPersisted.isEnabled
                || previousPersisted.authMethod != automaticallyPersisted.authMethod
                || previousPersisted.copilotAccountScope != automaticallyPersisted.copilotAccountScope
                || previousPersisted.githubOrganization != automaticallyPersisted.githubOrganization
                || previousPersisted.githubEnterprise != automaticallyPersisted.githubEnterprise
                || previousPersisted.copilotTotalAllotment != automaticallyPersisted.copilotTotalAllotment
                || previousPersisted.showsCursorGrokBotWeekly != automaticallyPersisted.showsCursorGrokBotWeekly
            guard shouldRefresh else {
                return
            }

            onAccountsInvalidated()
            Task {
                await onAccountRefreshRequested()
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

        Button(openCodeSaveButtonTitle) {
            saveOpenCodeCredential()
        }
        .disabled(
            !CredentialMutationFlow.canSaveOpenCodeSettings(
                enteredCredential: secret,
                hasSavedCredential: configurationStore.hasSecret(for: configuration),
                hasStagedSettings: hasStagedOpenCodeSettings
            )
        )

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
                CredentialMutationFlow.perform(
                    secret: "",
                    for: configuration,
                    using: configurationStore,
                    onFailure: { openCodeCredentialMessage = $0 },
                    onSuccess: {
                        secret = ""
                        openCodeCredentialMessage = "OpenCode credential removed."
                        requestCredentialRefresh()
                    }
                )
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
        case .error(let description):
            Label(description, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .missing:
            Label("No credentials configured yet", systemImage: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private var providerID: ProviderID {
        configuration.providerID
    }

    var dashboardMetrics: [DashboardMetricOption] {
        Self.dashboardMetrics(from: usageResult)
    }

    var metricsEmptyStateMessage: String {
        Self.metricsEmptyStateMessage(
            for: usageResult,
            isAccountEnabled: configuration.isEnabled
        )
    }

    var metricsRefreshFailureMessage: String? {
        Self.metricsRefreshFailureMessage(for: usageResult)
    }

    static func metricsRefreshFailureMessage(for result: ProviderUsageResult?) -> String? {
        guard let result, result.isIncompleteRefresh else {
            return nil
        }
        return "Could not discover dashboard metrics (\(result.subtitle)). "
            + "Select Refresh Metrics to try again."
    }

    static func metricsEmptyStateMessage(
        for result: ProviderUsageResult?,
        isAccountEnabled: Bool
    ) -> String {
        guard let result else {
            return isAccountEnabled
                ? "No metrics discovered yet. Refresh this account to load its dashboard metrics."
                : "Enable this account to discover its dashboard metrics."
        }
        if result.isIncompleteRefresh {
            return metricsRefreshFailureMessage(for: result) ?? "Metric discovery failed."
        }
        return "This account has no configurable dashboard metrics."
    }

    static func dashboardMetrics(from result: ProviderUsageResult?) -> [DashboardMetricOption] {
        guard let result else {
            return []
        }

        var seenKeys = Set<String>()
        return result.bars.compactMap { bar in
            guard
                let stableKey = bar.stableKey,
                !stableKey.isEmpty,
                seenKeys.insert(stableKey).inserted
            else {
                return nil
            }
            return DashboardMetricOption(id: stableKey, label: bar.label)
        }
    }

    static func metricAccessibilityLabel(accountName: String, metricName: String) -> String {
        "Show \(metricName) for \(accountName)"
    }

    private func setMetricVisibility(_ isVisible: Bool, stableKey: String) {
        if isVisible {
            configuration.hiddenDashboardMetricKeys.remove(stableKey)
        } else {
            configuration.hiddenDashboardMetricKeys.insert(stableKey)
        }
    }

    private func refreshMetrics() {
        guard !isRefreshingMetrics else {
            return
        }
        isRefreshingMetrics = true
        Task {
            let result = await onAccountRefresh(configuration)
            if let result {
                usageResult = result
            }
            isRefreshingMetrics = false
        }
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

    private func requestCredentialRefresh() {
        onCredentialInvalidated()
        Task {
            await onCredentialRefreshRequested()
        }
    }

    private func saveSecret() {
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSecret.isEmpty else {
            return
        }

        CredentialMutationFlow.perform(
            secret: trimmedSecret,
            for: configuration,
            using: configurationStore,
            onSuccess: {
                secret = ""
                requestCredentialRefresh()
            }
        )
    }

    private func removeSecret() {
        CredentialMutationFlow.perform(
            secret: "",
            for: configuration,
            using: configurationStore,
            onSuccess: {
                secret = ""
                requestCredentialRefresh()
            }
        )
    }

    private func removeBrowserCredential() {
        CredentialMutationFlow.perform(
            secret: "",
            for: configuration,
            using: configurationStore,
            onFailure: { error in
                codexAuthError = error
                claudeAuthError = error
                claudeAuthDiagnostic = nil
            },
            onSuccess: {
                codexAuthError = nil
                claudeAuthError = nil
                claudeAuthDiagnostic = nil
                requestCredentialRefresh()
            }
        )
    }

    private func removeCopilotCredential() {
        CredentialMutationFlow.perform(
            secret: "",
            for: configuration,
            using: configurationStore,
            onFailure: { copilotAuthError = $0 },
            onSuccess: {
                copilotAuthError = nil
                secret = ""
                requestCredentialRefresh()
            }
        )
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
            switch configurationStore.validateCodexAccountIdentity(
                result.accountID,
                for: configuration
            ) {
            case .available:
                break
            case .duplicate(let accountName):
                codexAuthError = "That ChatGPT account is already connected as “\(accountName)”. "
                    + "No saved account was changed. Try again with a different identity."
                return
            case .unableToVerify:
                codexAuthError = "ChatGPT sign-in completed, but CodexBar could not safely verify it "
                    + "against the other saved ChatGPT accounts. No saved account was changed. Try again."
                return
            }

            var updated = configuration
            updated.authMethod = .browserSession
            guard configurationStore.replaceCredential(result.storedCredential, for: updated) else {
                codexAuthError = configurationStore.lastError
                return
            }
            configuration = updated
            secret = ""
            onCredentialInvalidated()
            await onCredentialRefreshRequested()
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
            guard configurationStore.replaceCredential(result.storedCredential, for: updated) else {
                claudeAuthError = configurationStore.lastError
                claudeAuthDiagnostic = "Claude sign-in failed."
                return
            }
            configuration = updated
            secret = ""
            claudeAuthDiagnostic = "Claude sign-in complete."
            onCredentialInvalidated()
            await onCredentialRefreshRequested()
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
            guard configurationStore.replaceCredential(
                result.storedCredential(username: username),
                for: updated
            ) else {
                copilotAuthError = configurationStore.lastError
                return
            }
            configuration = updated
            secret = ""
            onCredentialInvalidated()
            await onCredentialRefreshRequested()
        } catch {
            copilotAuthError = Task.isCancelled
                ? "GitHub sign-in canceled. The existing account was not changed."
                : error.localizedDescription
        }
    }

    @MainActor
    private func saveOpenCodeCredential() {
        let savedCredentialReadResult = configurationStore.savedCredentialReadResult(for: configuration)
        let savedCredential: String? = if case .credential(let credential) = savedCredentialReadResult {
            credential
        } else {
            nil
        }
        guard let replacementCredential = CredentialMutationFlow.replacementCredential(
            enteredCredential: secret,
            savedCredential: savedCredential
        ) else {
            switch savedCredentialReadResult {
            case .failure(let description):
                openCodeCredentialMessage = description
                return
            case .credential:
                openCodeCredentialMessage = "The saved OpenCode credential is empty. Enter a replacement before saving."
                return
            case .missing:
                break
            }

            guard configurationStore.update(configuration) else {
                openCodeCredentialMessage = configurationStore.lastError
                return
            }

            openCodeCredentialMessage = "OpenCode settings saved. Add a dashboard auth value to refresh."
            onAccountsInvalidated()
            Task {
                await onAccountRefreshRequested()
            }
            return
        }

        guard configurationStore.replaceCredential(replacementCredential, for: configuration) else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }

        onCredentialInvalidated()
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

    private var openCodeSaveButtonTitle: String {
        if configurationStore.hasSecret(for: configuration) {
            return secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Save Settings and Refresh"
                : "Update and Refresh"
        }
        return secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Save Settings"
            : "Save and Refresh"
    }

    private var hasStagedOpenCodeSettings: Bool {
        configurationStore.configuration(accountID: accountID) != configuration
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
            return
        }

        if let balance = result.creditsRemaining {
            let formatted = Self.openCodeBalanceFormatter.string(from: NSNumber(value: balance)) ?? "$\(balance)"
            openCodeCredentialMessage = "OpenCode ZEN balance refreshed: \(formatted)"
        } else {
            openCodeCredentialMessage = result.subtitle
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
            onCredentialInvalidated()
            await onCredentialRefreshRequested()
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
        requestCredentialRefresh()
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
