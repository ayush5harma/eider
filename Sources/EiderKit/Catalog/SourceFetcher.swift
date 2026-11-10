import Foundation

/// Fetches one source document. Injected into `SourceStore` so tests and the
/// CLI can substitute their own.
public typealias SourceFetch = @Sendable (URL) async throws -> Data

public enum SourceFetcher {
    public static let maxBytes: Int64 = 20 * 1024 * 1024
    public static let timeout: TimeInterval = 30

    /// URLSession, 30 s, 20 MB, URL policy on the address and on every redirect.
    public static let `default`: SourceFetch = { url in
        try await fetch(url, configuration: .ephemeral, maxBytes: maxBytes)
    }

    static func fetch(_ url: URL, configuration: URLSessionConfiguration, maxBytes: Int64) async throws -> Data {
        guard URLPolicy.isAllowed(url, allowFile: true) else {
            throw CatalogFailure.blockedURL(url.absoluteString)
        }
        if url.isFileURL { return try readFile(url, maxBytes: maxBytes) }

        let configuration = configuration.copy() as? URLSessionConfiguration ?? configuration
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let transfer = HTTPTransfer(configuration: configuration)
        defer { transfer.invalidate() }

        var request = URLRequest(url: url, timeoutInterval: timeout)
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
