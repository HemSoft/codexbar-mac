import XCTest
import Darwin
@testable import CodexBarMac

enum RandomGeneratorTestError: Error {
    case failed
}

let syntheticOAuthCode = "redacted-authorization-code"

func deterministicOAuthRandomBytes(_ byteCount: Int) -> Data {
    Data((0..<byteCount).map { UInt8($0 % 251) })
}

func deterministicOAuthValue(byteCount: Int) -> String {
    deterministicOAuthRandomBytes(byteCount)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func formValues(from data: Data?) throws -> [String: String] {
    let body = try XCTUnwrap(data.flatMap { String(data: $0, encoding: .utf8) })
    let components = try XCTUnwrap(URLComponents(string: "?\(body)"))
    let pairs = (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    }
    let values = Dictionary(pairs) { first, _ in first }
    XCTAssertEqual(values.count, pairs.count, "Form body contains duplicate keys.")
    return values
}

func oauthCallbackTask(
    for authorizationURL: URL,
    code: String = syntheticOAuthCode
) -> Task<Void, Error>? {
    guard
        let authorizationComponents = URLComponents(
            url: authorizationURL,
            resolvingAgainstBaseURL: false
        ),
        let redirectURI = authorizationComponents.queryItemValue(named: "redirect_uri"),
        let state = authorizationComponents.queryItemValue(named: "state"),
        var callbackComponents = URLComponents(string: redirectURI)
    else {
        return nil
    }
    callbackComponents.queryItems = [
        URLQueryItem(name: "code", value: code),
        URLQueryItem(name: "state", value: state),
    ]
    guard let callbackURL = callbackComponents.url else {
        return nil
    }

    return Task.detached {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        let callbackSession = URLSession(configuration: configuration)
        defer { callbackSession.invalidateAndCancel() }
        let (_, response) = try await callbackSession.data(from: callbackURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}

@MainActor
func performTokenExchange<ExchangeResult>(
    expectedEndpoint: URL,
    statusCode: Int = 200,
    responseBody: Data,
    inspectRequest: @escaping (URLRequest, URL) throws -> Void,
    missingCallbackMessage: String,
    signIn: (URLSession, @escaping @MainActor (URL) -> Bool) async throws -> ExchangeResult
) async throws -> ExchangeResult {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    defer {
        MockURLProtocol.handler = nil
        session.invalidateAndCancel()
    }

    var presentedAuthorizationURL: URL?
    MockURLProtocol.handler = { request in
        let authorizationURL = try XCTUnwrap(presentedAuthorizationURL)
        XCTAssertEqual(request.url, expectedEndpoint)
        try inspectRequest(request, authorizationURL)
        return (
            HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!,
            responseBody
        )
    }

    var callbackTask: Task<Void, Error>?
    let result: Result<ExchangeResult, Error>
    do {
        result = .success(try await signIn(session) { authorizationURL in
            presentedAuthorizationURL = authorizationURL
            callbackTask = oauthCallbackTask(for: authorizationURL)
            return callbackTask != nil
        })
    } catch {
        result = .failure(error)
    }
    if let callbackTask {
        try await callbackTask.value
    } else {
        XCTFail(missingCallbackMessage)
    }
    return try result.get()
}

@MainActor
func performCodexTokenExchange(
    statusCode: Int = 200,
    responseBody: Data,
    inspectRequest: @escaping (URLRequest, URL) throws -> Void = { _, _ in }
) async throws -> CodexWebAuthResult {
    try await performTokenExchange(
        expectedEndpoint: CodexWebAuthService.tokenEndpoint,
        statusCode: statusCode,
        responseBody: responseBody,
        inspectRequest: inspectRequest,
        missingCallbackMessage: "Expected a deterministic ChatGPT loopback callback task."
    ) { session, presentAuthorizationURL in
        let service = CodexWebAuthService(
            session: session,
            callbackTimeoutNanoseconds: 2_000_000_000,
            randomBytes: deterministicOAuthRandomBytes
        )
        return try await service.signIn(presentAuthorizationURL: presentAuthorizationURL)
    }
}

@MainActor
func performClaudeTokenExchange(
    statusCode: Int = 200,
    responseBody: Data,
    inspectRequest: @escaping (URLRequest, URL) throws -> Void = { _, _ in }
) async throws -> ClaudeWebAuthResult {
    try await performTokenExchange(
        expectedEndpoint: URL(string: "https://platform.claude.com/v1/oauth/token")!,
        statusCode: statusCode,
        responseBody: responseBody,
        inspectRequest: inspectRequest,
        missingCallbackMessage: "Expected a deterministic Claude loopback callback task."
    ) { session, presentAuthorizationURL in
        let service = ClaudeWebAuthService(
            session: session,
            callbackTimeoutNanoseconds: 2_000_000_000,
            randomBytes: deterministicOAuthRandomBytes
        )
        return try await service.signIn(presentAuthorizationURL: presentAuthorizationURL)
    }
}

@MainActor
func performCopilotTokenExchange(
    statusCode: Int = 200,
    responseBody: Data,
    inspectRequest: @escaping (URLRequest, URL) throws -> Void = { _, _ in }
) async throws -> CopilotWebAuthResult {
    try await performTokenExchange(
        expectedEndpoint: CopilotWebAuthService.tokenEndpoint,
        statusCode: statusCode,
        responseBody: responseBody,
        inspectRequest: inspectRequest,
        missingCallbackMessage: "Expected a deterministic GitHub loopback callback task."
    ) { session, presentAuthorizationURL in
        let service = CopilotWebAuthService(
            session: session,
            callbackTimeoutNanoseconds: 2_000_000_000,
            randomBytes: deterministicOAuthRandomBytes
        )
        return try await service.signIn(
            configuration: CopilotOAuthConfiguration(
                clientID: "redacted-client-id",
                clientSecret: "redacted-client-secret"
            ),
            presentAuthorizationURL: presentAuthorizationURL
        )
    }
}

func makeLoopbackCallbackServer(
    preferredPorts: [UInt16],
    maximumRequestLength: Int = 8_192
) async throws -> LoopbackOAuthCallbackServer<ClaudeWebAuthService.AuthError> {
    try await LoopbackOAuthCallbackServer<ClaudeWebAuthService.AuthError>.start(
        preferredPorts: preferredPorts,
        expectedState: "expected-state",
        callbackPath: "/callback",
        bindHost: .ipv4,
        queueLabel: "com.hemsoft.CodexBarMacTests.loopbackOAuth.\(UUID().uuidString)",
        couldNotStartError: .couldNotStartCallbackServer,
        missingCodeError: .missingAuthorizationCode,
        stateMismatchError: .stateMismatch,
        timeoutError: .callbackTimedOut,
        successHeading: "Sign-in complete",
        failureHeading: "Sign-in failed",
        maximumRequestLength: maximumRequestLength
    )
}

func validLoopbackCallbackRequest(code: String = "authorization-code") -> Data {
    Data("GET /callback?code=\(code)&state=expected-state HTTP/1.1\r\n\r\n".utf8)
}

func sendRawHTTPRequest(
    port: UInt16,
    chunks: [Data],
    finishWriting: Bool = false
) async throws -> String {
    try await Task.detached {
        let socketDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(socketDescriptor) }

        var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &receiveTimeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connectionResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    socketDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard connectionResult == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        for (index, chunk) in chunks.enumerated() {
            try chunk.withUnsafeBytes { bytes in
                var sentByteCount = 0
                while sentByteCount < bytes.count {
                    let result = Darwin.send(
                        socketDescriptor,
                        bytes.baseAddress?.advanced(by: sentByteCount),
                        bytes.count - sentByteCount,
                        0
                    )
                    guard result > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    sentByteCount += result
                }
            }
            if index < chunks.count - 1 {
                usleep(50_000)
            }
        }

        if finishWriting {
            guard Darwin.shutdown(socketDescriptor, SHUT_WR) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let receivedByteCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(socketDescriptor, bytes.baseAddress, bytes.count, 0)
            }
            if receivedByteCount > 0 {
                response.append(contentsOf: buffer.prefix(receivedByteCount))
            } else if receivedByteCount == 0 {
                break
            } else if errno == ECONNRESET, !response.isEmpty {
                break
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        return String(decoding: response, as: UTF8.self)
    }.value
}
