import CryptoKit
import Foundation
import Security

public struct ClaudeWebAuthResult: Equatable, Sendable {
    public let credentials: ClaudeCredentials

    public var storedCredential: String {
        ClaudeCredentialsParser.storedCredential(from: credentials)
    }
}

public final class ClaudeWebAuthService: Sendable {
    public enum AuthError: LocalizedError, Equatable, Sendable {
        case couldNotStartCallbackServer
        case couldNotStartBrowserSession
        case missingAuthorizationCode
        case stateMismatch
        case callbackTimedOut
        case tokenExchangeFailed(String)
        case invalidTokenResponse

        public var errorDescription: String? {
            switch self {
            case .couldNotStartCallbackServer:
                "Could not start the local Claude login callback server."
            case .couldNotStartBrowserSession:
                "Could not open a private Claude sign-in session."
            case .missingAuthorizationCode:
                "Claude sign-in did not return an authorization code."
            case .stateMismatch:
                "Claude sign-in returned an unexpected state value."
            case .callbackTimedOut:
                "Claude sign-in did not return to the app. Try again, and complete sign-in in the browser."
            case .tokenExchangeFailed(let message):
                "Claude token exchange failed: \(message)"
            case .invalidTokenResponse:
                "Claude token exchange returned an invalid response."
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
        let expiresAt: Int64?
        let subscriptionType: String?
        let rateLimitTier: String?
        let error: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
            case subscriptionType = "subscription_type"
            case rateLimitTier = "rate_limit_tier"
            case error
        }
    }

    private static let authorizationBaseURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let callbackPath = "/callback"
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let requestedScope = "org:create_api_key user:profile user:inference user:sessions:claude_code"
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
        presentAuthorizationURL: @escaping @MainActor (URL) -> Bool,
        reportStage: @escaping @MainActor (String) -> Void = { _ in }
    ) async throws -> ClaudeWebAuthResult {
        reportStage("Starting Claude sign-in...")
        let state = Self.randomBase64URL(byteCount: 32)
        let pkce = Self.makePKCEPair()
        reportStage("Starting local callback server...")
        let callbackServer = try await LoopbackOAuthCallbackServer<AuthError>.start(
            preferredPorts: [1461, 1462, 1463],
            expectedState: state,
            callbackPath: Self.callbackPath,
            bindHost: .localhost,
            queueLabel: "com.hemsoft.CodexBarMac.claudeOAuthCallback",
            couldNotStartError: .couldNotStartCallbackServer,
            missingCodeError: .missingAuthorizationCode,
            stateMismatchError: .stateMismatch,
            timeoutError: .callbackTimedOut,
            successHeading: "Claude sign-in complete",
            failureHeading: "Claude sign-in failed",
            maximumRequestLength: 16_384
        )
        defer {
            callbackServer.cancel()
        }

        let redirectURI = "http://localhost:\(callbackServer.port)\(Self.callbackPath)"
        let authorizationURL = Self.authorizationURL(
            redirectURI: redirectURI,
            state: state,
            codeChallenge: pkce.codeChallenge
        )
        guard presentAuthorizationURL(authorizationURL) else {
            throw AuthError.couldNotStartBrowserSession
        }
        reportStage("Waiting for Claude to return to the app...")
        let callbackURL = try await callbackServer.waitForCallback(
            timeoutNanoseconds: callbackTimeoutNanoseconds
        )
        reportStage("Claude returned to the app. Exchanging authorization code...")

        let result = try await exchangeCallbackForTokens(
            callbackURL: callbackURL,
            redirectURI: redirectURI,
            state: state,
            pkce: pkce
        )
        reportStage("Claude token exchange succeeded.")
        return result
    }

    public static func authorizationURL(
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: authorizationBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: requestedScope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components.url!
    }

    public static func makeTokenRequestBody(
        code: String,
        redirectURI: String,
        state: String,
        codeVerifier: String
    ) -> Data {
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": codeVerifier,
            "state": state
        ]
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    public static func makePKCEPair() -> PKCEPair {
        let verifier = randomBase64URL(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = base64URLEncodedString(Data(digest))
        return PKCEPair(codeVerifier: verifier, codeChallenge: challenge)
    }

    private func exchangeCallbackForTokens(
        callbackURL: URL,
        redirectURI: String,
        state: String,
        pkce: PKCEPair
    ) async throws -> ClaudeWebAuthResult {
        guard
            let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
            components.queryItemValue(named: "state") == state
        else {
            throw AuthError.stateMismatch
        }
        guard let code = components.queryItemValue(named: "code"), !code.isEmpty else {
            throw AuthError.missingAuthorizationCode
        }
        return try await exchangeCodeForTokens(
            code: code,
            redirectURI: redirectURI,
            state: state,
            codeVerifier: pkce.codeVerifier
        )
    }

    private func exchangeCodeForTokens(
        code: String,
        redirectURI: String,
        state: String,
        codeVerifier: String
    ) async throws -> ClaudeWebAuthResult {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = Self.makeTokenRequestBody(
            code: code,
            redirectURI: redirectURI,
            state: state,
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

        let expiresAt = tokenResponse.expiresAt
            ?? tokenResponse.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)).unixTimeMilliseconds }
            ?? 0
        return ClaudeWebAuthResult(credentials: ClaudeCredentials(
            subscriptionType: tokenResponse.subscriptionType ?? "subscription",
            rateLimitTier: tokenResponse.rateLimitTier,
            expiresAt: expiresAt,
            accessToken: accessToken,
            refreshToken: tokenResponse.refreshToken
        ))
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URLEncodedString(Data(bytes))
    }

    private static func base64URLEncodedString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

private extension Date {
    var unixTimeMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1000).rounded())
    }
}
