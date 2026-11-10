import Foundation

/// URLProtocol stand-in for the network. Tests set `handler`, then read
/// `requests` to see exactly what Eider asked for (the Range header above all).
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        /// Send the headers and chunks, then neither finish nor fail (a stalled transfer).
        var hang = false
        var redirectTo: URL?
    }

    private static let lock = NSLock()
    private static var _handler: (@Sendable (URLRequest) -> Reply)?
    private static var _requests: [URLRequest] = []
    private static var _stops = 0

    static var handler: (@Sendable (URLRequest) -> Reply)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    static var requests: [URLRequest] { lock.withLock { _requests } }
    static var stopCount: Int { lock.withLock { _stops } }

    static func reset() {
        lock.withLock {
            _handler = nil
            _requests = []
            _stops = 0
        }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self._requests.append(request) }
        guard let url = request.url, let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let reply = handler(request)
        var headers = reply.headers
        if headers["Content-Length"] == nil {
            headers["Content-Length"] = String(reply.chunks.reduce(0) { $0 + $1.count })
        }
        guard let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers
        ) else { return }

        if let target = reply.redirectTo {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !reply.hang { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        Self.lock.withLock { Self._stops += 1 }
    }
}
