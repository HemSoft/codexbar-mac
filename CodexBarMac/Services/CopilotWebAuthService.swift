import CryptoKit
import Foundation
import Security

public struct CopilotWebAuthResult: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Int64?
    public let refreshTokenExpiresAt: Int64?

    public func storedCredential(username: String? = nil) -> String {
        CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: accessToken,
            username: username,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            refreshTokenExpiresAt: refreshTokenExpiresAt
        ))
    }
}

public struct CopilotOAuthConfiguration: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public static var bundled: CopilotOAuthConfiguration {
        // These public OAuth application credentials identify the Copilot
        // CLI-compatible app. Browser authorization and PKCE protect each
        // account sign-in; the values do not grant GitHub access on their own.
#if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let environmentClientID = environment["CODEXBAR_COPILOT_OAUTH_CLIENT_ID"]
        let environmentClientSecret = environment["CODEXBAR_COPILOT_OAUTH_CLIENT_SECRET"]
#else
        let environmentClientID: String? = nil
        let environmentClientSecret: String? = nil
#endif

        return CopilotOAuthConfiguration(
            clientID: environmentClientID
                ?? Bundle.main.object(forInfoDictionaryKey: "CODEXBAR_COPILOT_OAUTH_CLIENT_ID") as? String
                ?? "178c6fc778ccc68e1d6a",
            clientSecret: environmentClientSecret
                ?? Bundle.main.object(forInfoDictionaryKey: "CODEXBAR_COPILOT_OAUTH_CLIENT_SECRET") as? String
                ?? "34ddeff2b558a23d38fba8a6de74f086ede1cc0b"
        )
    }

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public final class CopilotWebAuthService: Sendable {
    deinit {}

    public enum AuthError: LocalizedError, Equatable, Sendable {
        case couldNotStartCallbackServer
        case couldNotStartBrowserSession
        case missingOAuthConfiguration
        case missingAuthorizationCode
        case stateMismatch
        case callbackTimedOut
        case tokenExchangeFailed(String)
        case invalidTokenResponse

        public var errorDescription: String? {
            switch self {
            case .couldNotStartCallbackServer:
                "Could not start the local GitHub login callback server."
            case .couldNotStartBrowserSession:
                "Could not open a private GitHub sign-in session."
            case .missingOAuthConfiguration:
                "GitHub sign-in is not configured in this build."
            case .missingAuthorizationCode:
                "GitHub sign-in did not return an authorization code."
            case .stateMismatch:
                "GitHub sign-in returned an unexpected state value."
            case .callbackTimedOut:
                "GitHub sign-in did not return to the app. Try again and complete sign-in in the browser."
            case .tokenExchangeFailed(let message):
                "GitHub token exchange failed: \(message)"
            case .invalidTokenResponse:
                "GitHub token exchange returned an invalid response."
            }
        }
    }

    public struct PKCEPair: Equatable, Sendable {
        public let codeVerifier: String
        public let codeChallenge: String
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int64?
        let refreshTokenExpiresIn: Int64?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case refreshTokenExpiresIn = "refresh_token_expires_in"
            case error
        }
    }

    private static let githubBaseURL = URL(string: "https://github.com")!
    public static let tokenEndpoint = githubBaseURL.appending(path: "/login/oauth/access_token")
    private static let callbackPath = "/callback"
    private static let requestedScope = "read:org"
    private let session: URLSession
    private let callbackTimeoutNanoseconds: UInt64

    public init(
        session: URLSession = .shared,
        callbackTimeoutNanoseconds: UInt64 = 180_000_000_000
    ) {
        self.session = session
        self.callbackTimeoutNanoseconds = callbackTimeoutNanoseconds
    }

    @MainActor
    public func signIn(
        configuration: CopilotOAuthConfiguration = .bundled,
        presentAuthorizationURL: @escaping @MainActor (URL) -> Bool
    ) async throws -> CopilotWebAuthResult {
        let clientID = configuration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = configuration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            throw AuthError.missingOAuthConfiguration
        }

        let state = Self.randomBase64URL(byteCount: 32)
        let pkce = Self.makePKCEPair()
        let callbackServer = try await LoopbackOAuthCallbackServer<AuthError>.start(
            preferredPorts: [1456, 1458, 1460],
            expectedState: state,
            callbackPath: Self.callbackPath,
            bindHost: .ipv4,
            queueLabel: "com.hemsoft.CodexBarMac.copilotOAuthCallback",
            couldNotStartError: .couldNotStartCallbackServer,
            missingCodeError: .missingAuthorizationCode,
            stateMismatchError: .stateMismatch,
            timeoutError: .callbackTimedOut,
            successHeading: "GitHub sign-in complete",
            failureHeading: "GitHub sign-in failed"
        )
        defer { callbackServer.cancel() }

        let redirectURI = "http://127.0.0.1:\(callbackServer.port)\(Self.callbackPath)"
        let authorizationURL = Self.authorizationURL(
            clientID: clientID,
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.codeChallenge
        )
        guard presentAuthorizationURL(authorizationURL) else {
            throw AuthError.couldNotStartBrowserSession
        }

        let callbackURL = try await callbackServer.waitForCallback(
            timeoutNanoseconds: callbackTimeoutNanoseconds
        )
        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.queryItemValue(named: "state") == state
        else {
            throw AuthError.stateMismatch
        }
        guard let code = components.queryItemValue(named: "code"), !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }

        return try await exchangeCodeForToken(
            clientID: clientID,
            clientSecret: clientSecret,
            code: code,
            redirectURI: redirectURI,
            codeVerifier: pkce.codeVerifier
        )
    }

    public static func authorizationURL(
        clientID: String,
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(
            url: githubBaseURL.appending(path: "/login/oauth/authorize"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: requestedScope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    public static func makeTokenRequestBody(
        clientID: String,
        clientSecret: String,
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) -> Data {
        OAuthFormEncoder.encode([
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
        ])
    }

    public static func makeRefreshTokenRequestBody(
        clientID: String,
        clientSecret: String,
        refreshToken: String
    ) -> Data {
        OAuthFormEncoder.encode([
            ("client_id", clientID),
            ("client_secret", clientSecret),
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
        ])
    }

    public static func makePKCEPair() -> PKCEPair {
        let verifier = randomBase64URL(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCEPair(
            codeVerifier: verifier,
            codeChallenge: Data(digest).base64URLEncodedString()
        )
    }

    private func exchangeCodeForToken(
        clientID: String,
        clientSecret: String,
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> CopilotWebAuthResult {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.makeTokenRequestBody(
            clientID: clientID,
            clientSecret: clientSecret,
            code: code,
            redirectURI: redirectURI,
            codeVerifier: codeVerifier
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidTokenResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AuthError.tokenExchangeFailed(
                TokenEndpointErrorFormatter.message(statusCode: httpResponse.statusCode, body: data)
            )
        }
        guard let tokenResponse = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidTokenResponse
        }
        if let error = tokenResponse.error {
            throw AuthError.tokenExchangeFailed(TokenEndpointErrorFormatter.message(errorCode: error))
        }
        guard let accessToken = tokenResponse.accessToken, !accessToken.isEmpty else {
            throw AuthError.invalidTokenResponse
        }

        let now = Date()
        return CopilotWebAuthResult(
            accessToken: accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: tokenResponse.expiresIn.map {
                Int64(now.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
            },
            refreshTokenExpiresAt: tokenResponse.refreshTokenExpiresIn.map {
                Int64(now.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
            }
        )
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

private extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
