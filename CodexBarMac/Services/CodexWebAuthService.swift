import CryptoKit
import Foundation
import Security

public struct CodexWebAuthResult: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountID: String?
    public let expiresAt: Int64?

    public var storedCredential: String {
        CodexCredentialsParser.storedCredential(from: CodexCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: idToken,
            accountID: accountID,
            expiresAt: expiresAt
        ))
    }
}

public struct CodexPKCEPair: Equatable, Sendable {
    public let codeVerifier: String
    public let codeChallenge: String
}

public final class CodexWebAuthService: Sendable {
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
                "Could not start the local login callback server."
            case .couldNotStartBrowserSession:
                "Could not open a private ChatGPT sign-in session."
            case .missingAuthorizationCode:
                "ChatGPT sign-in did not return an authorization code."
            case .stateMismatch:
                "ChatGPT sign-in returned an unexpected state value."
            case .callbackTimedOut:
                "ChatGPT sign-in did not return to the app. Try again and complete sign-in in the browser."
            case .tokenExchangeFailed(let message):
                "ChatGPT token exchange failed: \(message)"
            case .invalidTokenResponse:
                "ChatGPT token exchange returned an invalid response."
            }
        }
    }

    private struct TokenResponse: Decodable {
        let idToken: String?
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int64?
        let expiresAt: Int64?

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case expiresAt = "expires_at"
        }
    }

    private static let callbackPath = "/auth/callback"
    private static let issuer = URL(string: "https://auth.openai.com")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let tokenEndpoint = issuer.appending(path: "/oauth/token")
    private static let originator = "codex_cli_rs"
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
        presentAuthorizationURL: @escaping @MainActor (URL) -> Bool
    ) async throws -> CodexWebAuthResult {
        let state = Self.randomBase64URL(byteCount: 32)
        let pkce = Self.makePKCEPair()
        let callbackServer = try await LoopbackOAuthCallbackServer<AuthError>.start(
            preferredPorts: [1455, 1457],
            expectedState: state,
            callbackPath: Self.callbackPath,
            bindHost: .localhost,
            queueLabel: "com.hemsoft.CodexBarMac.codexOAuthCallback",
            couldNotStartError: .couldNotStartCallbackServer,
            missingCodeError: .missingAuthorizationCode,
            stateMismatchError: .stateMismatch,
            timeoutError: .callbackTimedOut,
            successHeading: "Sign-in complete",
            failureHeading: "Sign-in failed"
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

        return try await exchangeCodeForTokens(
            code: code,
            redirectURI: redirectURI,
            codeVerifier: pkce.codeVerifier
        )
    }

    public static func authorizationURL(
        redirectURI: String,
        state: String,
        codeChallenge: String
    ) -> URL {
        var components = URLComponents(url: issuer.appending(path: "/oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: originator)
        ]
        return components.url!
    }

    public static func makeTokenRequestBody(
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) -> Data {
        OAuthFormEncoder.encode([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", codeVerifier)
        ])
    }

    public static func makeRefreshTokenRequestBody(refreshToken: String) -> Data {
        OAuthFormEncoder.encode([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ])
    }

    public static func makePKCEPair() -> CodexPKCEPair {
        let verifier = randomBase64URL(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64URLEncodedString()
        return CodexPKCEPair(codeVerifier: verifier, codeChallenge: challenge)
    }

    public static func accountID(from token: String) -> String? {
        CodexCredentialsParser.parse(token)?.accountID
    }

    private func exchangeCodeForTokens(
        code: String,
        redirectURI: String,
        codeVerifier: String
    ) async throws -> CodexWebAuthResult {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.makeTokenRequestBody(
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
        guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw AuthError.invalidTokenResponse
        }

        let now = Date()
        let parsedAccessToken = CodexCredentialsParser.parse(tokens.accessToken)
        let parsedIDToken = tokens.idToken.flatMap(CodexCredentialsParser.parse)
        return CodexWebAuthResult(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            idToken: tokens.idToken,
            accountID: parsedIDToken?.accountID ?? parsedAccessToken?.accountID,
            expiresAt: tokens.expiresAt.map(CodexCredentials.normalizedEpochSeconds)
                ?? tokens.expiresIn.map { Int64(now.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970) }
                ?? parsedAccessToken?.expiresAt
                ?? parsedIDToken?.expiresAt
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
