import XCTest
@testable import CodexBarMac

func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer {
        stream.close()
    }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer {
        buffer.deallocate()
    }

    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read < 0 {
            return nil
        }
        if read == 0 {
            break
        }
        data.append(buffer, count: read)
    }

    return data
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

typealias IsolatedTestURLProtocolHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

private final class IsolatedTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let handlerIDHeader = "X-CodexBar-Test-Handler-ID"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: IsolatedTestURLProtocolHandler] = [:]

    static func register(_ handler: @escaping IsolatedTestURLProtocolHandler, for handlerID: String) {
        lock.withLock {
            handlers[handlerID] = handler
        }
    }

    static func unregister(handlerID: String) {
        _ = lock.withLock {
            handlers.removeValue(forKey: handlerID)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: handlerIDHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard
            let handlerID = request.value(forHTTPHeaderField: Self.handlerIDHeader),
            let handler = Self.lock.withLock({ Self.handlers[handlerID] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class IsolatedTestURLSession: @unchecked Sendable {
    let session: URLSession

    private let handlerID = UUID().uuidString
    private let lock = NSLock()
    private var isInvalidated = false

    init(handler: @escaping IsolatedTestURLProtocolHandler) {
        IsolatedTestURLProtocol.register(handler, for: handlerID)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [
            IsolatedTestURLProtocol.handlerIDHeader: handlerID,
        ]
        configuration.protocolClasses = [IsolatedTestURLProtocol.self]
        session = URLSession(configuration: configuration)
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        let shouldInvalidate = lock.withLock {
            guard !isInvalidated else { return false }
            isInvalidated = true
            return true
        }
        guard shouldInvalidate else { return }

        session.invalidateAndCancel()
        IsolatedTestURLProtocol.unregister(handlerID: handlerID)
    }
}

extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

extension String {
    func base64URLEncodedForTest() -> String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
