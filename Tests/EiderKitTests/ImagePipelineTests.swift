import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EiderKit

/// Test images and a loader that counts, waits and fails on request.
enum ImageFixtures {
    /// A square PNG with a gradient, so it does not compress to nothing.
    static func png(side: Int) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(
            colorsSpace: space,
            colors: [CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1), CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static let remoteSource = URL(string: "https://repo.example.com/source.json")!

    static func request(_ path: String, pixels: Int = 72) -> ImageRequest {
        ImageRequest(url: URL(string: "https://cdn.example.com/\(path)"), sourceURL: remoteSource, pixelSize: pixels)!
    }
}

final class LoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var _running = 0
    private var _peak = 0
    private var _cancelled = 0

    var calls: Int { lock.withLock { _calls } }
    var peak: Int { lock.withLock { _peak } }
    var cancelled: Int { lock.withLock { _cancelled } }

    /// A loader that takes `delay`, then returns `body` or throws `failure`.
    func loader(body: Data, delay: Duration = .milliseconds(30), failure: Error? = nil) -> ImagePipeline.Loader {
        { [self] _ in
            lock.withLock {
                _calls += 1
                _running += 1
                _peak = max(_peak, _running)
            }
            defer { lock.withLock { _running -= 1 } }
            do {
                try await Task.sleep(for: delay)
            } catch {
                lock.withLock { _cancelled += 1 }
                throw error
            }
            if let failure { throw failure }
            return body
        }
    }
}

final class ImagePipelineTests: XCTestCase {
    private let icon = ImageFixtures.png(side: 512)

    private func temporaryStore(limit: Int = ImagePipeline.defaultDiskLimit) throws -> ImageDiskStore {
        let paths = try CatalogFixtures.temporaryHome()
        return ImageDiskStore(directory: paths.cache.appendingPathComponent("Images"), limit: limit)
    }

    // MARK: Policy

    func testRequestsFollowTheSourcesURLPolicy() {
        let remote = ImageFixtures.remoteSource
        let loopbackSource = URL(string: "http://127.0.0.1:8080/source.json")!
        let fileSource = URL(fileURLWithPath: "/tmp/source.json")
        let https = URL(string: "https://cdn.example.com/a.png")!
        let loopback = URL(string: "http://127.0.0.1:8080/a.png")!
        let file = URL(fileURLWithPath: "/tmp/a.png")

        XCTAssertNotNil(ImageRequest(url: https, sourceURL: remote, pixelSize: 72))
        XCTAssertNil(ImageRequest(url: loopback, sourceURL: remote, pixelSize: 72), "a remote source must not reach this Mac")
        XCTAssertNil(ImageRequest(url: file, sourceURL: remote, pixelSize: 72), "a remote source must not read local files")
        XCTAssertNil(ImageRequest(url: URL(string: "http://cdn.example.com/a.png")!, sourceURL: remote, pixelSize: 72))
        XCTAssertNil(ImageRequest(url: file, sourceURL: nil, pixelSize: 72))
        XCTAssertNotNil(ImageRequest(url: loopback, sourceURL: loopbackSource, pixelSize: 72))
        XCTAssertNil(ImageRequest(url: file, sourceURL: loopbackSource, pixelSize: 72))
        XCTAssertNotNil(ImageRequest(url: file, sourceURL: fileSource, pixelSize: 72))
        XCTAssertNil(ImageRequest(url: loopback, sourceURL: fileSource, pixelSize: 72))
        XCTAssertNil(ImageRequest(url: nil, sourceURL: remote, pixelSize: 72))
        XCTAssertEqual(ImageRequest(url: https, sourceURL: remote, pixelSize: 1_000_000)?.pixelSize, ImageRequest.maxPixelSize)
    }

    // MARK: Fetching

    func testDownsamplesToTheRequestedPixelSize() async throws {
        let probe = LoaderProbe()
        let pipeline = ImagePipeline(store: nil, loader: probe.loader(body: ImageFixtures.png(side: 1024), delay: .zero))
        let image = await pipeline.image(for: ImageFixtures.request("big.png", pixels: 72))
        let decoded = try XCTUnwrap(image)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 72)
        XCTAssertGreaterThanOrEqual(max(decoded.width, decoded.height), 64)
    }

    func testOneFetchPerURLHoweverManyRowsAsk() async {
        let probe = LoaderProbe()
        let pipeline = ImagePipeline(store: nil, loader: probe.loader(body: icon, delay: .milliseconds(100)))
        let request = ImageFixtures.request("shared.png")
        let images = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<12 { group.addTask { await pipeline.image(for: request) != nil } }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        XCTAssertEqual(images, Array(repeating: true, count: 12))
        XCTAssertEqual(probe.calls, 1)
        // The bitmap is in memory now: no second fetch, and a synchronous hit.
        XCTAssertNotNil(pipeline.cachedImage(for: request))
        _ = await pipeline.image(for: request)
        XCTAssertEqual(probe.calls, 1)
    }

    func testNoMoreThanSixFetchesAtOnce() async {
        let probe = LoaderProbe()
        let pipeline = ImagePipeline(store: nil, loader: probe.loader(body: icon, delay: .milliseconds(40)))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<30 { group.addTask { _ = await pipeline.image(for: ImageFixtures.request("\(i).png")) } }
        }
        XCTAssertEqual(probe.calls, 30)
        XCTAssertLessThanOrEqual(probe.peak, ImagePipeline.defaultMaxConcurrentFetches)
        XCTAssertGreaterThan(probe.peak, 1, "fetches should overlap")
    }

    func testARowScrolledAwayCancelsItsFetchAndIsNotRememberedAsAFailure() async throws {
        let probe = LoaderProbe()
        let pipeline = ImagePipeline(store: nil, loader: probe.loader(body: icon, delay: .seconds(10)))
        let request = ImageFixtures.request("slow.png")
        let row = Task { await pipeline.image(for: request) }
        try await Task.sleep(for: .milliseconds(50))
        row.cancel()
        let result = await row.value
        XCTAssertNil(result)
        // The loader saw the cancellation instead of running its ten seconds.
        for _ in 0..<50 where probe.cancelled == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(probe.cancelled, 1)
        let inProgress = await pipeline.flightsInProgress
        XCTAssertEqual(inProgress, 0)

        // A second asker is not turned away by a remembered failure.
        let again = Task { await pipeline.image(for: request) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.calls, 2)
        again.cancel()
        _ = await again.value
    }

    func testOneRowLeavingDoesNotCancelTheFetchAnotherRowWaitsFor() async throws {
        let probe = LoaderProbe()
        let pipeline = ImagePipeline(store: nil, loader: probe.loader(body: icon, delay: .milliseconds(200)))
        let request = ImageFixtures.request("two.png")
        let leaving = Task { await pipeline.image(for: request) }
        let staying = Task { await pipeline.image(for: request) }
        try await Task.sleep(for: .milliseconds(50))
        leaving.cancel()
        let stayed = await staying.value
        XCTAssertNotNil(stayed)
        XCTAssertEqual(probe.calls, 1)
        XCTAssertEqual(probe.cancelled, 0)
    }

    func testFailuresAreRememberedBrieflyAndSilently() async throws {
        let probe = LoaderProbe()
        let pipeline = ImagePipeline(
            store: nil, loader: probe.loader(body: icon, delay: .zero, failure: ImageFetchError.status(404)),
            failureLifetime: .milliseconds(300))
        let request = ImageFixtures.request("dead.png")
        let first = await pipeline.image(for: request)
        let second = await pipeline.image(for: request)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(probe.calls, 1, "a dead URL is not fetched again on every scroll")
        try await Task.sleep(for: .milliseconds(400))
        _ = await pipeline.image(for: request)
        XCTAssertEqual(probe.calls, 2, "and is tried again once the failure has expired")
    }

    func testNonImageBytesAreAFailureAndAreNotStored() async throws {
        let store = try temporaryStore()
        let probe = LoaderProbe()
        let html = Data("<html><body>Not found</body></html>".utf8)
        let pipeline = ImagePipeline(store: store, loader: probe.loader(body: html, delay: .zero))
        let request = ImageFixtures.request("page.png")
        let image = await pipeline.image(for: request)
        XCTAssertNil(image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: request.url).path))
        _ = await pipeline.image(for: request)
        XCTAssertEqual(probe.calls, 1)
    }

    // MARK: Disk

    func testTheDiskCopyServesANewProcessWithoutTheNetwork() async throws {
        let store = try temporaryStore()
        let request = ImageFixtures.request("kept.png")
        let first = LoaderProbe()
        _ = await ImagePipeline(store: store, loader: first.loader(body: icon, delay: .zero)).image(for: request)
        XCTAssertEqual(first.calls, 1)

        let second = LoaderProbe()
        let restarted = ImagePipeline(store: store, loader: second.loader(body: icon, delay: .zero))
        let image = await restarted.image(for: request)
        XCTAssertNotNil(image)
        XCTAssertEqual(second.calls, 0)
        let hits = await restarted.diskHits
        XCTAssertEqual(hits, 1)
    }

    func testTheDiskStoreStaysWithinItsLimitDroppingTheLeastRecentlyUsed() throws {
        let store = try temporaryStore(limit: 10_000)
        let blob = Data(repeating: 7, count: 3_000)
        let urls = (0..<6).map { URL(string: "https://cdn.example.com/\($0).png")! }
        for (offset, url) in urls.enumerated() {
            XCTAssertEqual(store.write(blob, for: url), blob.count)
            // Distinct, ordered dates, oldest first.
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: Double(offset - 100))], ofItemAtPath: store.file(for: url).path)
        }
        // Reading the oldest makes it the most recently used.
        XCTAssertNotNil(store.read(urls[0]))
        let left = store.trim()
        XCTAssertLessThanOrEqual(left, Int(Double(store.limit) * ImageDiskStore.trimTarget))
        XCTAssertNotNil(store.read(urls[0]))
        XCTAssertNil(store.read(urls[1]))
        XCTAssertNotNil(store.read(urls[5]))
    }

    func testFileIconsFromAFileSourceAreReadWithoutTheDiskCache() async throws {
        let store = try temporaryStore()
        let directory = store.directory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let iconFile = directory.appendingPathComponent("icon.png")
        try icon.write(to: iconFile)
        let request = try XCTUnwrap(ImageRequest(
            url: iconFile, sourceURL: directory.appendingPathComponent("source.json"), pixelSize: 64))
        let pipeline = ImagePipeline(store: store, loader: { try await ImageFetcher().data(for: $0) })
        let image = await pipeline.image(for: request)
        XCTAssertNotNil(image)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: iconFile).path))
    }
}

/// The network half: status, content type, size cap and redirects, through
/// the same stub protocol the download tests use.
final class ImageFetcherTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    private let fetcher = ImageFetcher(configuration: StubURLProtocol.configuration())
    private let request = ImageFixtures.request("icon.png")

    func testReturnsAnImageBody() async throws {
        let png = ImageFixtures.png(side: 32)
        StubURLProtocol.handler = { _ in .init(headers: ["Content-Type": "image/png"], chunks: [png]) }
        let data = try await fetcher.data(for: request)
        XCTAssertEqual(data, png)
        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Accept"), "image/*")
    }

    func testRefusesHTMLAndErrors() async {
        StubURLProtocol.handler = { _ in .init(headers: ["Content-Type": "text/html"], chunks: [Data("<html>".utf8)]) }
        await assertThrows(ImageFetchError.notAnImage("text/html"))
        StubURLProtocol.handler = { _ in .init(status: 404, headers: ["Content-Type": "image/png"]) }
        await assertThrows(ImageFetchError.status(404))
    }

    func testAbandonsABodyOverFiveMegabytes() async {
        let chunk = Data(repeating: 1, count: 1 << 20)
        StubURLProtocol.handler = { _ in
            // No length announced: the cap has to hold while the bytes arrive.
            .init(headers: ["Content-Type": "image/png", "Content-Length": ""], chunks: Array(repeating: chunk, count: 7))
        }
        await assertThrows(ImageFetchError.tooLarge)
    }

    func testDoesNotFollowARedirectToThisMac() async {
        StubURLProtocol.handler = { _ in .init(status: 302, redirectTo: URL(string: "http://127.0.0.1:9/icon.png")!) }
        do {
            _ = try await fetcher.data(for: request)
            XCTFail("followed a redirect to loopback")
        } catch {
            XCTAssertEqual(error as? TransferError, .blockedRedirect(URL(string: "http://127.0.0.1:9/icon.png")!))
        }
    }

    private func assertThrows(_ expected: ImageFetchError, line: UInt = #line) async {
        do {
            _ = try await fetcher.data(for: request)
            XCTFail("no error", line: line)
        } catch {
            XCTAssertEqual(error as? ImageFetchError, expected, line: line)
        }
    }
}
