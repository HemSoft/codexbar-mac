import Foundation

public final class GeminiUsageProvider: UsageProvider {
    private static let refreshCoordinator = CredentialRefreshCoordinator<GeminiCredentialRefreshResult>()

    private let session: URLSession
    private let oauthFilePath: String
    private let quotaEndpoint: URL
    private let tierEndpoint: URL
    private let tokenEndpoint: URL
    private let now: @Sendable () -> Date
    private let tierCache = GeminiTierCache()

    public let providerID = ProviderID.gemini

    public init(
        session: URLSession = .shared,
        oauthFilePath: String = GeminiAuthFileStore.defaultPath(),
        quotaEndpoint: URL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!,
        tierEndpoint: URL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!,
        tokenEndpoint: URL = GeminiTokenRefresh.tokenEndpoint,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.oauthFilePath = oauthFilePath
        self.quotaEndpoint = quotaEndpoint
        self.tierEndpoint = tierEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard GeminiCLISettings.usesOAuthCredentials() else {
            return failureResult(
                "Gemini CLI is configured for API key or Vertex auth. CodexBar reads Gemini CLI OAuth credentials only.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        guard FileManager.default.fileExists(atPath: oauthFilePath) else {
            return failureResult(
                "No Gemini CLI credentials found. Run 'gemini' and complete login.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        guard let credentials = GeminiAuthFileStore.readCredentials(at: oauthFilePath) else {
            return failureResult(
                "Gemini credentials file exists but could not be read or is corrupted (\(oauthFilePath)). Delete the file and run 'gemini' to re-authenticate.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        switch await resolveAccessToken(for: credentials) {
        case .valid(let accessToken):
            return try await fetchUsage(
                configuration: configuration,
                accessToken: accessToken,
                canRefresh: true
            )
        case .transient:
            return failureResult(
                "Gemini token refresh failed temporarily. Try again later.",
                configuration: configuration,
                isIncompleteRefresh: true
            )
        case .rejected:
            return failureResult(
                "Gemini access token is expired or revoked and cannot be refreshed. Run 'gemini' to re-authenticate.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }
    }

    private func fetchUsage(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        canRefresh: Bool
    ) async throws -> ProviderUsageResult {
        await fetchTierIfNeeded(accessToken: accessToken, fingerprint: credentialFingerprint(for: accessToken))
        await tierCache.waitForInFlightFetchIfNeeded()

        let projectID = resolvedQuotaProjectID()
        let (data, response) = try await session.data(for: makeQuotaRequest(accessToken: accessToken, projectID: projectID))
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("Gemini usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let tierName = tierCache.currentTierName()
            guard let result = GeminiUsageParser.parseQuota(data, tierName: tierName, fetchedAt: now()) else {
                return failureResult("Could not parse Gemini usage.", configuration: configuration)
            }

            return ProviderUsageResult(
                accountID: configuration.id,
                providerID: providerID,
                title: configuration.displayName,
                subtitle: result.subtitle,
                bars: result.bars,
                fetchedAt: result.fetchedAt
            )
        case 401 where canRefresh:
            tierCache.invalidate()
            switch await refreshAccessToken(force: true) {
            case .valid(let refreshed):
                return try await fetchUsage(
                    configuration: configuration,
                    accessToken: refreshed,
                    canRefresh: false
                )
            case .transient:
                return failureResult(
                    "Gemini token refresh failed temporarily. Try again later.",
                    configuration: configuration,
                    isIncompleteRefresh: true
                )
            case .rejected:
                return failureResult(
                    "Gemini OAuth token invalid. Run 'gemini' and complete login.",
                    configuration: configuration,
                    isIncompleteRefresh: false
                )
            }
        case 401:
            tierCache.invalidate()
            return failureResult(
                "Gemini OAuth token invalid. Run 'gemini' and complete login.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        default:
            return failureResult(
                "Gemini usage request failed with status \(httpResponse.statusCode).",
                configuration: configuration
            )
        }
    }

    private enum AccessTokenResolution: Sendable {
        case valid(String)
        case rejected
        case transient
    }

    private func resolveAccessToken(for credentials: GeminiCredentials) async -> AccessTokenResolution {
        if let accessToken = credentials.accessToken,
           !accessToken.isEmpty,
           !credentials.shouldRefresh(at: now()) {
            return .valid(accessToken)
        }

        guard credentials.refreshToken?.isEmpty == false else {
            return .rejected
        }

        return await refreshAccessToken(force: false)
    }

    private func refreshAccessToken(force: Bool) async -> AccessTokenResolution {
        let result = await Self.refreshCoordinator.run(for: oauthFilePath) { [self] in
            if !force,
               let credentials = GeminiAuthFileStore.readCredentials(at: oauthFilePath),
               let accessToken = credentials.accessToken,
               !accessToken.isEmpty,
               !credentials.shouldRefresh(at: now()) {
                return GeminiCredentialRefreshResult.success(accessToken)
            }

            guard let credentials = GeminiAuthFileStore.readCredentials(at: oauthFilePath),
                  let refreshToken = credentials.refreshToken,
                  !refreshToken.isEmpty,
                  let clientID = GeminiTokenRefresh.resolveClientID(from: credentials),
                  let clientSecret = GeminiTokenRefresh.resolveClientSecret(from: credentials) else {
                return .rejected
            }

            do {
                var request = URLRequest(url: tokenEndpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = GeminiTokenRefresh.makeRefreshTokenRequestBody(
                    refreshToken: refreshToken,
                    clientID: clientID,
                    clientSecret: clientSecret
                )

                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    return .transient
                }

                if httpResponse.statusCode == 401 || httpResponse.statusCode == 400 {
                    return .rejected
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    return .transient
                }

                guard let tokenResponse = try? JSONDecoder().decode(GeminiTokenRefreshResponse.self, from: data) else {
                    return .transient
                }

                if let error = tokenResponse.error?.lowercased() {
                    if error == "invalid_grant" || error == "invalid_client" {
                        return .rejected
                    }
                    return .transient
                }

                guard let accessToken = tokenResponse.accessToken,
                      !accessToken.isEmpty else {
                    return .transient
                }

                let expiresIn = tokenResponse.expiresIn.flatMap { value in
                    (1...31_536_000).contains(value) ? value : nil
                } ?? 3_600
                let refreshedAt = now()
                let expiryDateMs = Int64(refreshedAt.addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1_000)
                let updated = GeminiCredentials(
                    accessToken: accessToken,
                    refreshToken: tokenResponse.refreshToken ?? credentials.refreshToken,
                    expiryDateMs: expiryDateMs,
                    idToken: tokenResponse.idToken ?? credentials.idToken
                )

                do {
                    try GeminiAuthFileStore.writeCredentials(updated, at: oauthFilePath)
                } catch {
                    return .transient
                }

                return .success(accessToken)
            } catch {
                return .transient
            }
        }

        switch result {
        case .success(let accessToken):
            return .valid(accessToken)
        case .rejected:
            return .rejected
        case .transient:
            return .transient
        }
    }

    private func fetchTierIfNeeded(accessToken: String, fingerprint: String) async {
        tierCache.prepare(for: fingerprint)

        guard tierCache.beginFetchIfNeeded() else {
            return
        }

        defer {
            tierCache.endFetchAttempt()
        }

        do {
            let (data, response) = try await session.data(for: makeTierRequest(accessToken: accessToken))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return
            }

            if let codeAssistInfo = GeminiUsageParser.parseCodeAssist(data) {
                tierCache.storeCodeAssistInfo(codeAssistInfo, fingerprint: fingerprint)
            } else {
                tierCache.markFetchComplete(fingerprint: fingerprint)
            }
        } catch {
            return
        }
    }

    private func credentialFingerprint(for accessToken: String) -> String {
        if let credentials = GeminiAuthFileStore.readCredentials(at: oauthFilePath) {
            if let refreshToken = credentials.refreshToken, !refreshToken.isEmpty {
                return "refresh:\(refreshToken)"
            }
            if let idToken = credentials.idToken, !idToken.isEmpty {
                return "id:\(idToken)"
            }
        }

        return "access:\(accessToken)"
    }

    private func resolvedQuotaProjectID() -> String? {
        if let projectID = tierCache.currentProjectID() {
            return projectID
        }

        for key in [
            "GOOGLE_CLOUD_QUOTA_PROJECT",
            "GOOGLE_CLOUD_PROJECT",
            "GOOGLE_CLOUD_PROJECT_ID",
            "GEMINI_CLOUD_PROJECT",
        ] {
            if let value = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func makeQuotaRequest(accessToken: String, projectID: String?) -> URLRequest {
        var request = URLRequest(url: quotaEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let projectID {
            request.httpBody = (try? JSONSerialization.data(withJSONObject: ["project": projectID])) ?? Data("{}".utf8)
        } else {
            request.httpBody = Data("{}".utf8)
        }
        return request
    }

    private func makeTierRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: tierEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(
            #"{"metadata":{"ideType":"GEMINI_CLI","pluginType":"GEMINI"}}"#.utf8
        )
        return request
    }

    private func failureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration,
        isIncompleteRefresh: Bool = true
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            isIncompleteRefresh: isIncompleteRefresh,
            fetchedAt: now()
        )
    }
}

private enum GeminiCredentialRefreshResult: Sendable {
    case success(String)
    case rejected
    case transient
}

private final class GeminiTierCache: @unchecked Sendable {
    deinit {}

    private let lock = NSLock()
    private var tierName: String?
    private var projectID: String?
    private var credentialFingerprint: String?
    private var fetched = false
    private var fetchInProgress = false
    private var fetchWaiters: [CheckedContinuation<Void, Never>] = []

    func prepare(for fingerprint: String) {
        lock.withLock {
            guard credentialFingerprint != fingerprint else {
                return
            }

            credentialFingerprint = fingerprint
            tierName = nil
            projectID = nil
            fetched = false
        }
    }

    func currentTierName() -> String? {
        lock.withLock { tierName }
    }

    func currentProjectID() -> String? {
        lock.withLock { projectID }
    }

    func beginFetchIfNeeded() -> Bool {
        lock.withLock {
            if fetched || fetchInProgress {
                return false
            }
            fetchInProgress = true
            return true
        }
    }

    func endFetchAttempt() {
        resumeWaiters()
    }

    func waitForInFlightFetchIfNeeded() async {
        let shouldWait = lock.withLock { fetchInProgress && !fetched }
        guard shouldWait else {
            return
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.withLock {
                if !fetchInProgress || fetched {
                    continuation.resume()
                } else {
                    fetchWaiters.append(continuation)
                }
            }
        }
    }

    func storeCodeAssistInfo(_ info: GeminiUsageParser.CodeAssistInfo, fingerprint: String) {
        lock.withLock {
            guard credentialFingerprint == fingerprint else {
                return
            }
            if let tierName = info.tierName {
                self.tierName = tierName
            }
            if let projectID = info.projectID {
                self.projectID = projectID
            }
            fetched = true
        }
        resumeWaiters()
    }

    func markFetchComplete(fingerprint: String) {
        lock.withLock {
            guard credentialFingerprint == fingerprint else {
                return
            }
            fetched = true
        }
        resumeWaiters()
    }

    private func resumeWaiters() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            fetchInProgress = false
            let pending = fetchWaiters
            fetchWaiters = []
            return pending
        }

        for waiter in waiters {
            waiter.resume()
        }
    }

    func invalidate() {
        let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            tierName = nil
            projectID = nil
            credentialFingerprint = nil
            fetched = false
            fetchInProgress = false
            let pending = fetchWaiters
            fetchWaiters = []
            return pending
        }

        for waiter in waiters {
            waiter.resume()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
