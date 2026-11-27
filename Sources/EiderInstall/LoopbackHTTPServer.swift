import Foundation
import Network
import Security

/// What a route answers with.
struct HTTPResource {
    enum Body {
        case data(Data)
        case file(URL)
    }

    let body: Body
    let contentType: String
    let size: Int64

    static func data(_ data: Data, contentType: String) -> HTTPResource {
        HTTPResource(body: .data(data), contentType: contentType, size: Int64(data.count))
    }

    static func file(_ url: URL, contentType: String) throws -> HTTPResource {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return HTTPResource(body: .file(url), contentType: contentType, size: size)
    }
}

/// A minimal HTTP/1.1 server on 127.0.0.1 only, one request per connection.
///
/// Serves GET and HEAD with single byte ranges; anything a route does not know is a 404. Each
/// response ends with `Connection: close`, which keeps the parser to one request head and
/// costs nothing over loopback.
final class LoopbackHTTPServer: @unchecked Sendable {
    typealias Router = (HTTPRequest) -> HTTPResource?

    struct ServerError: Error, CustomStringConvertible {
        let description: String
    }

    /// Body bytes of a GET that the network stack has taken: the path and the byte interval.
    var onBodySent: ((String, Range<Int64>) -> Void)?
    /// Every request that was answered, with its status code.
    var onResponse: ((HTTPRequest, Int) -> Void)?
    /// The listener failed after it was ready.
    var onFailure: ((Error) -> Void)?

    static let maximumHeadSize = 16 * 1024
    /// One send at a time, 512 KiB each: memory stays bounded however large the IPA is.
    static let chunkSize = 512 * 1024
    static let requestTimeout: TimeInterval = 30

    private let identity: SecIdentity?
    private let router: Router
    private let queue = DispatchQueue(label: "dev.eider.install.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// - Parameter identity: TLS identity; nil serves plain HTTP.
    init(identity: SecIdentity?, router: @escaping Router) {
        self.identity = identity
        self.router = router
    }

    /// Starts listening on a free port of 127.0.0.1 and returns that port.
    func start() async throws -> UInt16 {
        let parameters = try makeParameters()
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    return continuation.resume(throwing: ServerError(description: "The server went away."))
                }
                self.listener = listener
                self.startContinuation = continuation
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(to: state) }
                listener.start(queue: self.queue)
            }
        }
    }

    /// Resumed once, on `queue`, when the listener is ready or could not start.
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    private func listenerChanged(to state: NWListener.State) {
        let continuation = startContinuation
        switch state {
        case .ready:
            startContinuation = nil
            if let port = listener?.port?.rawValue {
                continuation?.resume(returning: port)
            } else {
                continuation?.resume(throwing: ServerError(description: "The listener has no port."))
            }
        case .failed(let error), .waiting(let error):
            startContinuation = nil
            if let continuation { continuation.resume(throwing: error) } else { onFailure?(error) }
            listener?.cancel()
        case .cancelled:
            startContinuation = nil
            continuation?.resume(throwing: ServerError(description: "The listener was cancelled."))
        default:
            break
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
        }
    }

    private func makeParameters() throws -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        let parameters: NWParameters
        if let identity {
            let tls = NWProtocolTLS.Options()
            guard let secIdentity = sec_identity_create(identity) else {
                throw ServerError(description: "The server identity cannot be used for TLS.")
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        // Bound to the loopback address and interface so nothing off the device can connect.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        return parameters
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[id] = nil
                self?.answered.remove(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil, !self.answered.contains(id) else { return }
            connection.cancel()
        }
        receiveHead(on: connection, buffer: Data())
    }

    /// Connections whose request head arrived; the rest are dropped after `requestTimeout`.
    private var answered: Set<ObjectIdentifier> = []

    private func receiveHead(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumHeadSize) {
            [weak self] content, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let content { buffer.append(content) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.answered.insert(ObjectIdentifier(connection))
                self.respond(to: buffer[..<end.lowerBound], on: connection)
            } else if buffer.count > Self.maximumHeadSize {
                self.sendError(431, "Request Header Fields Too Large", on: connection, request: nil)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.receiveHead(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to head: Data, on connection: NWConnection) {
        guard let request = HTTPRequest.parse(head: Data(head)) else {
            return sendError(400, "Bad Request", on: connection, request: nil)
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            return sendError(405, "Method Not Allowed", on: connection, request: request,
                             extraHeaders: [("Allow", "GET, HEAD")])
        }
        guard let resource = router(request) else {
            return sendError(404, "Not Found", on: connection, request: request)
        }

        var headers: [(String, String)] = [
            ("Content-Type", resource.contentType),
            ("Accept-Ranges", "bytes"),
            ("Cache-Control", "no-store"),
        ]
        let status: Int
        let range: ClosedRange<Int64>?
        switch ByteRange.evaluate(request.headers["range"], size: resource.size) {
        case .full:
            status = 200
            range = resource.size > 0 ? 0...(resource.size - 1) : nil
        case .partial(let partial):
            status = 206
            range = partial
            headers.append(("Content-Range", "bytes \(partial.lowerBound)-\(partial.upperBound)/\(resource.size)"))
        case .unsatisfiable:
            return sendError(416, "Range Not Satisfiable", on: connection, request: request,
                             extraHeaders: [("Content-Range", "bytes */\(resource.size)")])
        }
        let length = range.map { $0.upperBound - $0.lowerBound + 1 } ?? 0
        headers.append(("Content-Length", String(length)))
        onResponse?(request, status)

        let head = Self.head(status: status, reason: status == 206 ? "Partial Content" : "OK", headers: headers)
        connection.send(content: head, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return connection.cancel() }
            guard request.method == "GET", let range else { return self.finish(connection) }
            do {
                let reader = try BodyReader(resource.body, range: range)
                self.sendBody(reader, path: request.path, on: connection)
            } catch {
                self.onFailure?(error)
                connection.cancel()
            }
        })
    }

    private func sendBody(_ reader: BodyReader, path: String, on connection: NWConnection) {
        let chunk: (offset: Int64, data: Data)?
        do {
            chunk = try reader.next(maximum: Self.chunkSize)
        } catch {
            onFailure?(error)
            return connection.cancel()
        }
        guard let chunk else { return finish(connection) }
        connection.send(content: chunk.data, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return connection.cancel() }
            self.onBodySent?(path, chunk.offset..<(chunk.offset + Int64(chunk.data.count)))
            self.sendBody(reader, path: path, on: connection)
        })
    }

    private func finish(_ connection: NWConnection) {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendError(_ status: Int, _ reason: String, on connection: NWConnection, request: HTTPRequest?,
                           extraHeaders: [(String, String)] = []) {
        if let request { onResponse?(request, status) }
        let body = Data("\(status) \(reason)\n".utf8)
        let head = Self.head(status: status, reason: reason, headers: extraHeaders + [
            ("Content-Type", "text/plain; charset=utf-8"),
            ("Content-Length", String(body.count)),
        ])
        let payload = request?.method == "HEAD" ? head : head + body
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.finish(connection)
        })
    }

    private static func head(status: Int, reason: String, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason)\r\n"
        for (name, value) in headers + [("Connection", "close")] { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// Reads a resource's body in chunks over a byte range.
private final class BodyReader {
    private let source: HTTPResource.Body
    private let handle: FileHandle?
    private var offset: Int64
    private let end: Int64 // exclusive

    init(_ source: HTTPResource.Body, range: ClosedRange<Int64>) throws {
        self.source = source
        self.offset = range.lowerBound
        self.end = range.upperBound + 1
        if case .file(let url) = source {
            let handle = try FileHandle(forReadingFrom: url)
            try handle.seek(toOffset: UInt64(range.lowerBound))
            self.handle = handle
        } else {
            self.handle = nil
        }
    }

    deinit { try? handle?.close() }

    func next(maximum: Int) throws -> (offset: Int64, data: Data)? {
        guard offset < end else { return nil }
        let count = Int(min(Int64(maximum), end - offset))
        let data: Data
        switch source {
        case .data(let all):
            data = all.subdata(in: Int(offset)..<(Int(offset) + count))
        case .file:
            data = try handle?.read(upToCount: count) ?? Data()
            guard !data.isEmpty else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The file ended early."])
            }
        }
        let start = offset
        offset += Int64(data.count)
        return (start, data)
    }
}
