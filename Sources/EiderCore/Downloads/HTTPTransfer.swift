import Foundation

enum TransferEvent: Sendable {
    case response(HTTPURLResponse)
    case data(Data)
}

enum TransferError: Error, Equatable {
    case blockedRedirect(URL)
    case notHTTP
}

/// One URLSession, one stream of events per request. A delegate hands out data
/// in the chunks the network delivers; `URLSession.bytes` yields one byte at a
/// time through an async iterator, which is too slow for multi-gigabyte IPAs.
///
/// Redirects are checked against `URLPolicy`: an https address that bounces to
/// plain http (or to a local file) is refused rather than followed.
final class HTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Stream = AsyncThrowingStream<TransferEvent, Error>

    private let lock = NSLock()
    private var continuations: [Int: Stream.Continuation] = [:]
    private var session: URLSession?

    init(configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Ends the stream when the consumer stops iterating, which cancels the transfer.
    func events(for request: URLRequest) -> Stream {
        Stream { continuation in
            guard let task = session?.dataTask(with: request) else {
                continuation.finish(throwing: URLError(.cancelled))
                return
            }
            register(continuation, for: task.taskIdentifier)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    func invalidate() {
        session?.invalidateAndCancel()
    }

    // MARK: Bookkeeping

    private func register(_ continuation: Stream.Continuation, for id: Int) {
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
    }

    private func continuation(for id: Int) -> Stream.Continuation? {
        lock.lock()
        defer { lock.unlock() }
        return continuations[id]
    }

    private func finish(_ id: Int, error: Error?) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: id)
        lock.unlock()
        if let error {
            continuation?.finish(throwing: error)
        } else {
            continuation?.finish()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(dataTask.taskIdentifier, error: TransferError.notHTTP)
            completionHandler(.cancel)
            return
        }
        continuation(for: dataTask.taskIdentifier)?.yield(.response(http))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation(for: dataTask.taskIdentifier)?.yield(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(task.taskIdentifier, error: error)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Loopback is followed only from a request that was itself to loopback: an
        // https address must not be able to bounce this Mac into its own services.
        let startedOnLoopback = task.originalRequest?.url.map(URLPolicy.isLoopbackURL) ?? false
        if let target = request.url, URLPolicy.isAllowed(target, allowLoopback: startedOnLoopback) {
            completionHandler(request)
            return
        }
        finish(task.taskIdentifier, error: TransferError.blockedRedirect(request.url ?? response.url ?? URL(fileURLWithPath: "/")))
        completionHandler(nil)
    }
}
