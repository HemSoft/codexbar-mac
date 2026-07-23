import Foundation
import Network

enum OAuthFormEncoder {
    private static let allowedCharacters: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    static func encode(_ pairs: [(String, String)]) -> Data {
        let encoded = pairs
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
    }
}

enum TokenEndpointErrorFormatter {
    private static let maximumErrorCodeLength = 64
    private static let allowedErrorCodeCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
    )

    static func message(statusCode: Int, body: Data) -> String {
        let statusMessage = "HTTP \(statusCode)"
        guard let errorCode = oauthErrorCode(from: body) else {
            return statusMessage
        }
        return "\(statusMessage) (\(errorCode))"
    }

    static func message(errorCode: String) -> String {
        safeOAuthErrorCode(errorCode) ?? "Token endpoint rejected the request."
    }

    private static func oauthErrorCode(from body: Data) -> String? {
        guard
            let object = try? JSONSerialization.jsonObject(with: body),
            let dictionary = object as? [String: Any],
            let errorCode = dictionary["error"] as? String
        else {
            return nil
        }
        return safeOAuthErrorCode(errorCode)
    }

    private static func safeOAuthErrorCode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            trimmed.utf8.count <= maximumErrorCodeLength,
            trimmed.unicodeScalars.allSatisfy(allowedErrorCodeCharacters.contains)
        else {
            return nil
        }
        return trimmed
    }
}

enum LoopbackOAuthBindHost {
    case localhost
    case ipv4

    fileprivate var endpointHost: NWEndpoint.Host {
        switch self {
        case .localhost:
            Self.preferredLocalhostLoopbackHost()
        case .ipv4:
            .ipv4(.loopback)
        }
    }

    private static func preferredLocalhostLoopbackHost() -> NWEndpoint.Host {
        var addresses: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("localhost", nil, nil, &addresses) == 0, let addresses else {
            return .ipv4(.loopback)
        }
        defer { freeaddrinfo(addresses) }

        var address: UnsafeMutablePointer<addrinfo>? = addresses
        while let candidate = address {
            switch candidate.pointee.ai_family {
            case AF_INET6:
                return .ipv6(.loopback)
            case AF_INET:
                return .ipv4(.loopback)
            default:
                address = candidate.pointee.ai_next
            }
        }
        return .ipv4(.loopback)
    }
}

final class LoopbackOAuthCallbackServer<AuthError: LocalizedError & Sendable>: @unchecked Sendable {
    let port: UInt16

    private let expectedState: String
    private let callbackPath: String
    private let couldNotStartError: AuthError
    private let missingCodeError: AuthError
    private let stateMismatchError: AuthError
    private let timeoutError: AuthError
    private let successHeading: String
    private let failureHeading: String
    private let maximumRequestLength: Int
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallbackResult: Result<URL, Error>?
    private var callbackFinished = false

    private init(
        port: UInt16,
        expectedState: String,
        callbackPath: String,
        bindHost: LoopbackOAuthBindHost,
        queueLabel: String,
        couldNotStartError: AuthError,
        missingCodeError: AuthError,
        stateMismatchError: AuthError,
        timeoutError: AuthError,
        successHeading: String,
        failureHeading: String,
        maximumRequestLength: Int
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw couldNotStartError
        }

        self.port = port
        self.expectedState = expectedState
        self.callbackPath = callbackPath
        self.couldNotStartError = couldNotStartError
        self.missingCodeError = missingCodeError
        self.stateMismatchError = stateMismatchError
        self.timeoutError = timeoutError
        self.successHeading = successHeading
        self.failureHeading = failureHeading
        self.maximumRequestLength = maximumRequestLength
        self.queue = DispatchQueue(label: queueLabel)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: bindHost.endpointHost, port: nwPort)
        self.listener = try NWListener(using: parameters)
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }
    }

    static func start(
        preferredPorts: [UInt16],
        expectedState: String,
        callbackPath: String,
        bindHost: LoopbackOAuthBindHost,
        queueLabel: String,
        couldNotStartError: AuthError,
        missingCodeError: AuthError,
        stateMismatchError: AuthError,
        timeoutError: AuthError,
        successHeading: String,
        failureHeading: String,
        maximumRequestLength: Int = 8192
    ) async throws -> LoopbackOAuthCallbackServer<AuthError> {
        var lastError: Error = couldNotStartError
        for port in preferredPorts {
            do {
                let server = try LoopbackOAuthCallbackServer(
                    port: port,
                    expectedState: expectedState,
                    callbackPath: callbackPath,
                    bindHost: bindHost,
                    queueLabel: queueLabel,
                    couldNotStartError: couldNotStartError,
                    missingCodeError: missingCodeError,
                    stateMismatchError: stateMismatchError,
                    timeoutError: timeoutError,
                    successHeading: successHeading,
                    failureHeading: failureHeading,
                    maximumRequestLength: maximumRequestLength
                )
                try await server.startListening()
                return server
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func waitForCallback(timeoutNanoseconds: UInt64) async throws -> URL {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
            } catch {
                return
            }
            guard let self else { return }
            finishCallback(.failure(timeoutError))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let pendingCallbackResult {
                    self.pendingCallbackResult = nil
                    lock.unlock()
                    continuation.resume(with: pendingCallbackResult)
                    return
                }
                callbackContinuation = continuation
                lock.unlock()
            }
        } onCancel: {
            finishCallback(.failure(CancellationError()))
        }
    }

    func cancel() {
        listener.cancel()
    }

    private func startListening() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readyContinuation = continuation
            lock.unlock()
            listener.start(queue: queue)
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            finishReady(.success(()))
        case .failed(let error):
            finishReady(.failure(error))
            finishCallback(.failure(error))
        case .cancelled:
            finishReady(.failure(couldNotStartError))
            finishCallback(.failure(missingCodeError))
        default:
            break
        }
    }

    private func finishReady(_ result: Result<Void, Error>) {
        lock.lock()
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func finishCallback(_ result: Result<URL, Error>) {
        lock.lock()
        guard !callbackFinished else {
            lock.unlock()
            return
        }
        callbackFinished = true
        if let continuation = callbackContinuation {
            callbackContinuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingCallbackResult = result
            lock.unlock()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(from: connection, accumulatedData: Data())
    }

    private func receiveRequest(from connection: NWConnection, accumulatedData: Data) {
        let remainingLength = maximumRequestLength - accumulatedData.count
        guard remainingLength > 0 else {
            completeRequest(
                on: connection,
                result: .failure(missingCodeError),
                failureStatusLine: "HTTP/1.1 413 Payload Too Large"
            )
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: remainingLength) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var requestData = accumulatedData
            if let data, !data.isEmpty {
                requestData.append(data)
            }

            if let headerRange = requestData.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = requestData[..<headerRange.upperBound]
                let request = String(data: headerData, encoding: .utf8) ?? ""
                completeRequest(on: connection, result: parseCallbackURL(from: request))
                return
            }

            if requestData.count >= maximumRequestLength {
                completeRequest(
                    on: connection,
                    result: .failure(missingCodeError),
                    failureStatusLine: "HTTP/1.1 413 Payload Too Large"
                )
                return
            }

            if error != nil || isComplete {
                completeRequest(on: connection, result: .failure(missingCodeError))
                return
            }

            receiveRequest(from: connection, accumulatedData: requestData)
        }
    }

    private func completeRequest(
        on connection: NWConnection,
        result: Result<URL, Error>,
        failureStatusLine: String = "HTTP/1.1 400 Bad Request"
    ) {
        let response = httpResponse(for: result, failureStatusLine: failureStatusLine)
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
        finishCallback(result)
    }

    private func parseCallbackURL(from request: String) -> Result<URL, Error> {
        guard
            let requestLine = request.components(separatedBy: "\r\n").first,
            requestLine.hasPrefix("GET "),
            let pathStart = requestLine.firstIndex(of: " "),
            let pathEnd = requestLine[requestLine.index(after: pathStart)...].firstIndex(of: " ")
        else {
            return .failure(missingCodeError)
        }

        let path = String(requestLine[requestLine.index(after: pathStart)..<pathEnd])
        guard path.hasPrefix(callbackPath) else {
            return .failure(missingCodeError)
        }
        guard let url = URL(string: "http://localhost:\(port)\(path)") else {
            return .failure(missingCodeError)
        }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState
        else {
            return .failure(stateMismatchError)
        }
        guard components.queryItems?.first(where: { $0.name == "code" })?.value?.isEmpty == false else {
            return .failure(missingCodeError)
        }
        return .success(url)
    }

    private func httpResponse(
        for result: Result<URL, Error>,
        failureStatusLine: String = "HTTP/1.1 400 Bad Request"
    ) -> String {
        let statusLine: String
        let heading: String
        let message: String
        switch result {
        case .success:
            statusLine = "HTTP/1.1 200 OK"
            heading = successHeading
            message = "You can return to CodexBar."
        case .failure(let error):
            statusLine = failureStatusLine
            heading = failureHeading
            message = error.localizedDescription
        }

        let body = """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
        <body><h1>\(heading)</h1><p>\(message)</p></body></html>
        """
        return """
        \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(Data(body.utf8).count)\r
        Connection: close\r
        \r
        \(body)
        """
    }
}
