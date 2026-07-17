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

        guard let accessToken = await validAccessToken(for: credentials) else {
            return failureResult(
                "Gemini access token is expired or revoked and cannot be refreshed. Run 'gemini' to re-authenticate.",
                configuration: configuration,
                isIncompleteRefresh: false
            )
        }

        return try await fetchUsage(
            configuration: configuration,
            accessToken: accessToken,
            canRefresh: true
        )
    }

    private func fetchUsage(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        canRefresh: Bool
    ) async throws -> ProviderUsageResult {
        if tierCache.shouldFetch() {
            await fetchTierIfNeeded(accessToken: accessToken)
        }

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
            guard let refreshed = await refreshCredentials(force: true) else {
                return failureResult(
                    "Gemini OAuth token invalid. Run 'gemini' and complete login.",
                    configuration: configuration,
                    isIncompleteRefresh: false
                )
            }

            return try await fetchUsage(
                configuration: configuration,
                accessToken: refreshed,
                canRefresh: false
            )
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

    private func validAccessToken(for credentials: GeminiCredentials) async -> String? {
        if let accessToken = credentials.accessToken,
           !accessToken.isEmpty,
           !credentials.shouldRefresh(at: now()) {
            return accessToken
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return nil
        }

        return await refreshCredentials(force: false)
    }

    private func refreshCredentials(force: Bool) async -> String? {
        let result = await Self.refreshCoordinator.run(for: oauthFilePath) { [self] in
            if !force,
               let credentials = GeminiAuthFileStore.readCredentials(at: oauthFilePath),
               let accessToken = credentials.accessToken,
               !accessToken.isEmpty,
               !credentials.shouldRefresh(at: now()) {
                return .success(accessToken)
            }

            guard let credentials = GeminiAuthFileStore.readCredentials(at: oauthFilePath),
                  let refreshToken = credentials.refreshToken,
                  !refreshToken.isEmpty,
                  let clientID = GeminiTokenRefresh.resolveClientID(from: credentials),
                  let clientSecret = GeminiTokenRefresh.resolveClientSecret(from: credentials) else {
                return .failure
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
                    return .failure
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    return .failure
                }

                guard let tokenResponse = try? JSONDecoder().decode(GeminiTokenRefreshResponse.self, from: data),
                      tokenResponse.error == nil,
                      let accessToken = tokenResponse.accessToken,
                      !accessToken.isEmpty else {
                    return .failure
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
                    return .failure
                }

                return .success(accessToken)
            } catch {
                return .failure
            }
        }

        if case .success(let accessToken) = result {
            return accessToken
        }

        return nil
    }

    private func fetchTierIfNeeded(accessToken: String) async {
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
                tierCache.storeCodeAssistInfo(codeAssistInfo)
            } else {
                tierCache.markFetchComplete()
            }
        } catch {
            return
        }
    }

    private func resolvedQuotaProjectID() -> String? {
        if let projectID = tierCache.currentProjectID() {
            return projectID
        }

        for key in ["GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT_ID", "GEMINI_CLOUD_PROJECT"] {
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
    case failure
}

private final class GeminiTierCache: @unchecked Sendable {
    private let lock = NSLock()
    private var tierName: String?
    private var projectID: String?
    private var fetched = false
    private var fetchInProgress = false

    func shouldFetch() -> Bool {
        lock.withLock { !fetched }
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
        lock.withLock {
            fetchInProgress = false
        }
    }

    func storeCodeAssistInfo(_ info: GeminiUsageParser.CodeAssistInfo) {
        lock.withLock {
            if let tierName = info.tierName {
                self.tierName = tierName
            }
            if let projectID = info.projectID {
                self.projectID = projectID
            }
            fetched = true
            fetchInProgress = false
        }
    }

    func markFetchComplete() {
        lock.withLock {
            fetched = true
            fetchInProgress = false
        }
    }

    func invalidate() {
        lock.withLock {
            tierName = nil
            projectID = nil
            fetched = false
            fetchInProgress = false
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
