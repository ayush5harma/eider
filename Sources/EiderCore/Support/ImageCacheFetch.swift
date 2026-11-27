import Foundation

public enum ImageFetchError: Error, Equatable {
    case status(Int)
    case notAnImage(String)
    case tooLarge
    case notAllowed
}

/// Bytes for an image request, from the network (https, or http to this Mac
/// for a loopback source) or from disk (a source the owner added as a file).
/// Redirects follow `URLPolicy` through `HTTPTransfer`. A body over
/// `maxBytes` is abandoned as it arrives, not after it is all in memory.
struct ImageFetcher: Sendable {
    /// Icons are tens of KB; screenshots a few hundred. 5 MB is generous.
    static let maxBytes = 5 << 20
    private static let timeout: TimeInterval = 20

    private let transfer: HTTPTransfer

    init(configuration: URLSessionConfiguration = ImageFetcher.defaultConfiguration()) {
        transfer = HTTPTransfer(configuration: configuration)
    }

    /// No URLCache: the pipeline keeps its own disk copy, keyed and bounded the
    /// way the browser needs, and two caches would hold every icon twice.
    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = ImagePipeline.defaultMaxConcurrentFetches
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        return configuration
    }

    func data(for request: ImageRequest) async throws -> Data {
        guard request.isAllowed else { throw ImageFetchError.notAllowed }
        if request.url.isFileURL { return try fileData(at: request.url) }
        var urlRequest = URLRequest(url: request.url, timeoutInterval: Self.timeout)
        urlRequest.setValue("image/*", forHTTPHeaderField: "Accept")
        var body = Data()
        for try await event in transfer.events(for: urlRequest) {
            switch event {
            case .response(let response):
                guard (200..<300).contains(response.statusCode) else { throw ImageFetchError.status(response.statusCode) }
                if let type = response.mimeType?.lowercased(), !Self.acceptsMIMEType(type) {
                    throw ImageFetchError.notAnImage(type)
                }
                if response.expectedContentLength > Self.maxBytes { throw ImageFetchError.tooLarge }
                if response.expectedContentLength > 0 { body.reserveCapacity(Int(response.expectedContentLength)) }
            case .data(let chunk):
                body.append(chunk)
                if body.count > Self.maxBytes { throw ImageFetchError.tooLarge }
            }
            try Task.checkCancellation()
        }
        return body
    }

    /// Image hosts label icons `image/*`; object stores often say octet-stream.
    /// HTML and JSON (an error page, a login wall) are not worth decoding.
    static func acceptsMIMEType(_ type: String) -> Bool {
        type.hasPrefix("image/") || type == "application/octet-stream" || type == "binary/octet-stream"
    }

    private func fileData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImageFetchError.notAnImage("not a file") }
        guard (values.fileSize ?? 0) <= Self.maxBytes else { throw ImageFetchError.tooLarge }
        return try Data(contentsOf: url)
    }
}

/// At most `limit` holders at once; a cancelled waiter leaves the queue
/// without ever taking a slot.
actor FetchLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextID = 0

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// True when the caller holds a slot and must `release()` it.
    func acquire() async -> Bool {
        if Task.isCancelled { return false }
        if running < limit {
            running += 1
            return true
        }
        nextID += 1
        let id = nextID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append((id, $0)) }
        } onCancel: {
            Task { await self.abandon(id) }
        }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            // The slot passes straight to the next waiter.
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func abandon(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    var inUse: Int { running }
}
