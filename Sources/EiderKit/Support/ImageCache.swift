import CoreGraphics
import Foundation

/// One image at one size. Built only for an address `URLPolicy` allows for the
/// source it came from: https always; a file only from a source that is itself
/// a file; http to this Mac only from a loopback source. A remote source can
/// never make Eider read a local file or call a service on this Mac.
public struct ImageRequest: Hashable, Sendable {
    public let url: URL
    /// The longer side of the bitmap wanted, in pixels (points x backing scale).
    public let pixelSize: Int
    let allowFile: Bool
    let allowLoopback: Bool

    public static let maxPixelSize = 2048

    public init?(url: URL?, sourceURL: URL?, pixelSize: Int) {
        guard let url else { return nil }
        let allowFile = sourceURL?.isFileURL ?? false
        let allowLoopback = sourceURL.map(URLPolicy.isLoopbackURL) ?? false
        guard URLPolicy.isAllowed(url, allowFile: allowFile, allowLoopback: allowLoopback) else { return nil }
        self.url = url
        self.pixelSize = min(max(pixelSize, 1), Self.maxPixelSize)
        self.allowFile = allowFile
        self.allowLoopback = allowLoopback
    }

    var isAllowed: Bool { URLPolicy.isAllowed(url, allowFile: allowFile, allowLoopback: allowLoopback) }
    var memoryKey: NSString { "\(pixelSize)|\(url.absoluteString)" as NSString }
}

/// Remote icons and screenshots for the window: memory cache, disk cache,
/// de-duplicated and rate-limited fetches, downsampling off the main actor.
///
/// - Memory: decoded bitmaps in an NSCache keyed by URL and pixel size, cost
///   in bytes, so scrolling back up the list draws from memory at once.
/// - Disk: the fetched bytes in `<EIDER_HOME>/Cache/Images`, bounded by
///   `diskLimit`, least recently used first out.
/// - Network: at most `maxConcurrentFetches` at a time; one fetch per URL
///   however many rows ask; abandoned when every asker has been cancelled
///   (a row scrolled away before its icon came).
/// - Failures are remembered for `failureLifetime` and are silent: the row
///   keeps its placeholder and a dead host is not asked again on every scroll.
public actor ImagePipeline {
    public typealias Loader = @Sendable (ImageRequest) async throws -> Data

    public static let defaultMaxConcurrentFetches = 6
    public static let defaultDiskLimit = 300 << 20
    public static let defaultMemoryLimit = 96 << 20

    public static let shared = ImagePipeline(
        store: ImageDiskStore(
            directory: EiderPaths().cache.appendingPathComponent("Images", isDirectory: true),
            limit: defaultDiskLimit),
        loader: { [fetcher = ImageFetcher()] in try await fetcher.data(for: $0) })

    private enum Outcome: Sendable {
        case data(Data)
        case failed
        case cancelled
    }

    private final class Flight {
        let id: Int
        var task: Task<Outcome, Never>?
        var askers: Set<Int> = []

        init(id: Int) { self.id = id }
    }

    private nonisolated let memory: ImageMemoryCache
    private let store: ImageDiskStore?
    private let loader: Loader
    private let limiter: FetchLimiter
    private let failureLifetime: Duration
    private var failures: [URL: ContinuousClock.Instant] = [:]
    private var flights: [URL: Flight] = [:]
    private var nextID = 0
    /// Bytes on disk: measured at the first write, then kept by addition and
    /// corrected by each trim. Only decides when to trim, so it may run a
    /// little behind the truth.
    private var diskBytes = 0
    private var diskMeasured = false
    private var trimming = false

    /// Counters for the tests and the performance log.
    public private(set) var networkFetches = 0
    public private(set) var diskHits = 0

    init(
        store: ImageDiskStore?, loader: @escaping Loader,
        maxConcurrentFetches: Int = defaultMaxConcurrentFetches,
        memoryLimit: Int = defaultMemoryLimit,
        failureLifetime: Duration = .seconds(300)
    ) {
        self.store = store
        self.loader = loader
        self.limiter = FetchLimiter(limit: maxConcurrentFetches)
        self.failureLifetime = failureLifetime
        self.memory = ImageMemoryCache(limit: memoryLimit)
    }

    /// A bitmap already in memory. Synchronous and cheap (a hash lookup), so a
    /// row coming back on screen draws its icon in the first frame.
    public nonisolated func cachedImage(for request: ImageRequest) -> CGImage? {
        memory.image(for: request.memoryKey)
    }

    /// The bitmap for `request`, or nil when it cannot be had (blocked, dead,
    /// not an image, or the caller was cancelled). Never throws: a missing icon
    /// is not an error anyone needs to see.
    public func image(for request: ImageRequest) async -> CGImage? {
        if let hit = cachedImage(for: request) { return hit }
        guard request.isAllowed, !recentlyFailed(request.url) else { return nil }
        guard case .data(let data) = await data(for: request) else { return nil }
        let size = request.pixelSize
        // Utility, not userInitiated: with 120 icons decoding at once the main
        // actor's longest wait fell from 18.6 ms to 12 ms and the batch got no
        // slower (ImagePipelinePerformanceTests). Scrolling matters more.
        let decoded = await Task.detached(priority: .utility) {
            ImageDecoder.downsample(data, maxPixelSize: size).map(CGImageBox.init)
        }.value
        guard let decoded else {
            // Bytes that were checked as an image and still do not decode: drop
            // the disk copy and stop asking for a while.
            store?.remove(request.url)
            failures[request.url] = .now
            return nil
        }
        memory.insert(decoded, for: request.memoryKey)
        return decoded.image
    }

    // MARK: Fetching, once per URL

    private func data(for request: ImageRequest) async -> Outcome {
        let url = request.url
        let flight = flights[url] ?? startFlight(for: request)
        nextID += 1
        let asker = nextID
        flight.askers.insert(asker)
        let outcome = await withTaskCancellationHandler {
            await flight.task?.value ?? .cancelled
        } onCancel: {
            Task { await self.leave(url, flight: flight.id, asker: asker) }
        }
        flight.askers.remove(asker)
        if case .failed = outcome { failures[url] = .now }
        return Task.isCancelled ? .cancelled : outcome
    }

    private func startFlight(for request: ImageRequest) -> Flight {
        nextID += 1
        let flight = Flight(id: nextID)
        flights[request.url] = flight
        let store = store, loader = loader, limiter = limiter, id = flight.id
        // Detached: disk reads and decoding checks must not run on this actor.
        flight.task = Task.detached(priority: .utility) { [weak self] in
            let outcome = await Self.fetch(request, store: store, loader: loader, limiter: limiter, pipeline: self)
            await self?.land(request.url, flight: id)
            return outcome
        }
        return flight
    }

    private static func fetch(
        _ request: ImageRequest, store: ImageDiskStore?, loader: Loader, limiter: FetchLimiter, pipeline: ImagePipeline?
    ) async -> Outcome {
        let cacheable = !request.url.isFileURL
        if cacheable, let data = store?.read(request.url) {
            await pipeline?.countDiskHit()
            return .data(data)
        }
        guard await limiter.acquire() else { return .cancelled }
        let result: Result<Data, Error>
        do {
            await pipeline?.countNetworkFetch()
            result = .success(try await loader(request))
        } catch {
            result = .failure(error)
        }
        await limiter.release()
        switch result {
        case .failure(let error):
            return Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                ? .cancelled : .failed
        case .success(let data):
            guard ImageDecoder.isImage(data) else { return .failed }
            if cacheable, let store, let written = store.write(data, for: request.url) {
                await pipeline?.recordWrite(written, store: store)
            }
            return .data(data)
        }
    }

    private func leave(_ url: URL, flight id: Int, asker: Int) {
        guard let flight = flights[url], flight.id == id else { return }
        flight.askers.remove(asker)
        if flight.askers.isEmpty {
            flight.task?.cancel()
            flights[url] = nil
        }
    }

    private func land(_ url: URL, flight id: Int) {
        if flights[url]?.id == id { flights[url] = nil }
    }

    private func recentlyFailed(_ url: URL) -> Bool {
        guard let when = failures[url] else { return false }
        if ContinuousClock.now - when < failureLifetime { return true }
        failures[url] = nil
        return false
    }

    private func countDiskHit() { diskHits += 1 }
    private func countNetworkFetch() { networkFetches += 1 }

    private func recordWrite(_ bytes: Int, store: ImageDiskStore) async {
        diskBytes += bytes
        guard !trimming, !diskMeasured || diskBytes > store.limit else { return }
        trimming = true
        diskBytes = await Task.detached(priority: .utility) { store.trim() }.value
        diskMeasured = true
        trimming = false
    }

    /// Fetches still running, for the tests.
    var flightsInProgress: Int { flights.count }
}

/// NSCache wants objects; the cost is what the bitmap occupies.
final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    var cost: Int { image.bytesPerRow * image.height }

    init(_ image: CGImage) { self.image = image }
}

/// NSCache is documented as safe to use from any thread; this wrapper only
/// says so to the compiler, so the window can look up a hit synchronously.
final class ImageMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CGImageBox>()

    init(limit: Int) { cache.totalCostLimit = limit }

    func image(for key: NSString) -> CGImage? { cache.object(forKey: key)?.image }
    func insert(_ box: CGImageBox, for key: NSString) { cache.setObject(box, forKey: key, cost: box.cost) }
}
