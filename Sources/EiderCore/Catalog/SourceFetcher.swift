import Foundation

/// Fetches one source document. Injected into `SourceStore` so tests and the
/// CLI can substitute their own.
public typealias SourceFetch = @Sendable (URL) async throws -> Data

public enum SourceFetcher {
    /// Bounds the buffer and the JSON decode. The largest source seen in use,
    /// fastsign.dev/repo.json on 2026-11-26, is 22.8 MB with 17,430 apps and was
    /// refused by the old 20 MB cap; 64 MB leaves it room to grow about threefold.
    public static let maxBytes: Int64 = 64 * 1024 * 1024
    /// Seconds without a single byte arriving before the fetch fails.
    public static let idleTimeout: TimeInterval = 30
    /// Backstop for a server that trickles bytes forever: 15 minutes moves the
    /// 64 MB cap at about 73 KB/s. The 22.8 MB source above took 112 s (about
    /// 210 KB/s) on 2026-11-26.
    public static let overallTimeout: TimeInterval = 900

    /// URLSession, 30 s idle, 64 MB, URL policy on the address and on every redirect.
    public static let `default`: SourceFetch = { url in
        try await fetch(url, configuration: .ephemeral, maxBytes: maxBytes)
    }

    static func fetch(_ url: URL, configuration: URLSessionConfiguration, maxBytes: Int64) async throws -> Data {
        guard URLPolicy.isAllowed(url, allowFile: true, allowLoopback: true) else {
            throw CatalogFailure.blockedURL(url.absoluteString)
        }
        if url.isFileURL { return try readFile(url, maxBytes: maxBytes) }

        let configuration = configuration.copy() as? URLSessionConfiguration ?? configuration
        configure(configuration)
        let transfer = HTTPTransfer(configuration: configuration)
        defer { transfer.invalidate() }

        var request = URLRequest(url: url, timeoutInterval: idleTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = Data()
        do {
            for try await event in transfer.events(for: request) {
                switch event {
                case .response(let response):
                    try check(response, maxBytes: maxBytes)
                case .data(let chunk):
                    body.append(chunk)
                    if Int64(body.count) > maxBytes { throw CatalogFailure.tooLarge(limit: maxBytes) }
                }
            }
        } catch let failure as CatalogFailure {
            throw failure
        } catch let TransferError.blockedRedirect(target) {
            throw CatalogFailure.blockedURL(target.absoluteString)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CatalogFailure.fetchFailed(error.localizedDescription)
        }
        return body
    }

    /// `timeoutIntervalForRequest` is URLSession's idle timer (it restarts with every
    /// packet); the whole-transfer timer is `timeoutIntervalForResource`, which
    /// used to equal it and failed a large source on a slow link.
    static func configure(_ configuration: URLSessionConfiguration) {
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = overallTimeout
    }

    private static func check(_ response: HTTPURLResponse, maxBytes: Int64) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw CatalogFailure.fetchFailed("the server answered HTTP \(response.statusCode)")
        }
        if response.expectedContentLength > maxBytes { throw CatalogFailure.tooLarge(limit: maxBytes) }
    }

    private static func readFile(_ url: URL, maxBytes: Int64) throws -> Data {
        do {
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64 ?? 0
            if size > maxBytes { throw CatalogFailure.tooLarge(limit: maxBytes) }
            return try Data(contentsOf: url)
        } catch let failure as CatalogFailure {
            throw failure
        } catch {
            throw CatalogFailure.fetchFailed(error.localizedDescription)
        }
    }
}
