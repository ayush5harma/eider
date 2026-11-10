import CryptoKit
import XCTest
@testable import EiderKit

final class DownloadsManagerTests: XCTestCase {
    private let url = URL(string: "https://cdn.example.com/app.ipa")!
    /// 3000 distinct-ish bytes, so a wrongly stitched resume cannot compare equal.
    private let body = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 / 251) })
    private var paths: EiderPaths!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        paths = try CatalogFixtures.temporaryHome()
    }

    override func tearDown() { StubURLProtocol.reset() }

    // MARK: Helpers

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func app(_ bundleID: String = "com.example.app", version: String = "1.0",
                     sha256: String? = nil, url: URL? = nil) -> (CatalogApp, CatalogVersion) {
        let release = CatalogVersion(version: version, downloadURL: url ?? self.url, sha256: sha256)
        return (CatalogApp(bundleID: bundleID, name: "App", versions: [release]), release)
    }

    private func manager(maxBytes: Int64 = 1 << 20) -> DownloadManager {
        DownloadManager(paths: paths, configuration: StubURLProtocol.configuration(), maxBytes: maxBytes)
    }

    private func run(_ manager: DownloadManager, _ pair: (CatalogApp, CatalogVersion),
                     allowChangedHash: Bool = false) async throws -> [DownloadEvent] {
        var events: [DownloadEvent] = []
        for try await event in manager.download(pair.1, of: pair.0, allowChangedHash: allowChangedHash) {
            events.append(event)
        }
        return events
    }

    private func expectFailure(_ expected: DownloadFailure, _ work: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await work()
            XCTFail("expected \(expected.code)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DownloadFailure, expected, file: file, line: line)
        }
    }

    private func serve(_ data: Data, chunk: Int = 1000) {
        StubURLProtocol.handler = { request in
            let total = data.count
            let chunks = stride(from: 0, to: total, by: chunk).map { data[$0..<min($0 + chunk, total)] }
            guard let range = request.value(forHTTPHeaderField: "Range"),
                  let start = Int(range.dropFirst("bytes=".count).dropLast())
            else { return .init(chunks: chunks.map { Data($0) }) }
            let rest = data[start...]
            return .init(status: 206, headers: ["Content-Range": "bytes \(start)-\(total - 1)/\(total)"],
                         chunks: [Data(rest)])
        }
    }

    private func destination(_ name: String = "com.example.app-1.0.ipa") -> URL {
        paths.downloads.appendingPathComponent(name)
    }

    private func plantPart(_ prefix: Data, name: String = "com.example.app-1.0.ipa.part") throws {
        try paths.ensure()
        try prefix.write(to: paths.downloads.appendingPathComponent(name))
    }

    // MARK: Fresh, resume, restart

    func testFreshDownload() async throws {
        serve(body)
        let events = try await run(manager(), app())

        XCTAssertEqual(events.first, .started(expectedBytes: 3000))
        XCTAssertEqual(events.last, .finished(file: destination(), sha256: sha(body)))
        XCTAssertTrue(events.contains(.progress(received: 3000, expected: 3000)))
        XCTAssertEqual(try Data(contentsOf: destination()), body)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path + ".part"))
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        let record = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: paths.hashesFile))
        XCTAssertEqual(record[url.absoluteString], sha(body))
    }

    func testResumesAPartFileWithARangeRequest() async throws {
        try plantPart(body.prefix(1200))
        serve(body)
        let events = try await run(manager(), app())

        XCTAssertEqual(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=1200-")
        XCTAssertEqual(events.first, .started(expectedBytes: 3000), "expected is the whole file")
        XCTAssertTrue(events.contains(.progress(received: 3000, expected: 3000)))
        XCTAssertEqual(try Data(contentsOf: destination()), body)
    }

    func testRestartsCleanlyWhenTheServerIgnoresRange() async throws {
        try plantPart(Data(repeating: 0xEE, count: 1200))
        StubURLProtocol.handler = { [body] _ in .init(chunks: [body]) }
        _ = try await run(manager(), app())

        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        XCTAssertEqual(try Data(contentsOf: destination()), body, "stale bytes must not survive")
    }

    func testRestartsWhenTheRangeIsRefusedAsUnsatisfiable() async throws {
        try plantPart(Data(repeating: 0xEE, count: 1200))
        StubURLProtocol.handler = { [body] request in
            request.value(forHTTPHeaderField: "Range") != nil ? .init(status: 416) : .init(chunks: [body])
        }
        _ = try await run(manager(), app())

        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertNil(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Range"))
        XCTAssertEqual(try Data(contentsOf: destination()), body)
    }

    func testRestartsWhenContentRangeStartsInTheWrongPlace() async throws {
        try plantPart(body.prefix(1200))
        StubURLProtocol.handler = { [body] request in
            if request.value(forHTTPHeaderField: "Range") != nil {
                return .init(status: 206, headers: ["Content-Range": "bytes 0-2999/3000"], chunks: [body])
            }
            return .init(chunks: [body])
        }
        _ = try await run(manager(), app())
        XCTAssertEqual(try Data(contentsOf: destination()), body)
    }

    // MARK: Limits and policy

    func testCapIsEnforcedOnContentLength() async {
        StubURLProtocol.handler = { _ in .init(headers: ["Content-Length": "5000"], chunks: []) }
        await expectFailure(.sizeCapExceeded(limit: 4000)) { _ = try await run(manager(maxBytes: 4000), app()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
    }

    func testCapIsEnforcedOnBytesActuallyReceivedAndTheDiscardLeavesNoPart() async {
        StubURLProtocol.handler = { _ in
            .init(headers: ["Content-Length": "100"], chunks: [Data(count: 1500), Data(count: 1500), Data(count: 1500)])
        }
        await expectFailure(.sizeCapExceeded(limit: 4000)) { _ = try await run(manager(maxBytes: 4000), app()) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path + ".part"))
    }

    func testPlainHTTPIsRefusedWithoutARequest() async throws {
        let insecure = URL(string: "http://cdn.example.com/app.ipa")!
        await expectFailure(.blockedURL(insecure.absoluteString)) {
            _ = try await run(manager(), app(url: insecure))
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testRedirectToPlainHTTPIsRefused() async {
        StubURLProtocol.handler = { _ in .init(status: 302, redirectTo: URL(string: "http://evil.example.com/a.ipa")!) }
        await expectFailure(.blockedURL("http://evil.example.com/a.ipa")) { _ = try await run(manager(), app()) }
    }

    func testHTTPErrorStatus() async {
        StubURLProtocol.handler = { _ in .init(status: 503) }
        await expectFailure(.httpStatus(503)) { _ = try await run(manager(), app()) }
    }

    func testShortBodyKeepsThePartForResume() async throws {
        StubURLProtocol.handler = { [body] _ in
            .init(headers: ["Content-Length": "3000"], chunks: [body.prefix(1000)])
        }
        await expectFailure(.incomplete(received: 1000, expected: 3000)) { _ = try await run(manager(), app()) }
        XCTAssertEqual(try Data(contentsOf: destination("com.example.app-1.0.ipa.part")).count, 1000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
    }

    func testHostileNamesStayInsideTheDownloadsFolder() async throws {
        serve(body)
        let events = try await run(manager(), app("../../evil/app", version: "1/2"))
        guard case .finished(let file, _) = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL.path,
                       paths.downloads.standardizedFileURL.path)
        XCTAssertFalse(file.lastPathComponent.contains("/"))
    }

    // MARK: Hashes

    func testDeclaredHashMismatchDeletesTheFile() async throws {
        serve(body)
        let wrong = String(repeating: "0", count: 64)
        await expectFailure(.hashMismatch(expected: wrong, actual: sha(body))) {
            _ = try await run(manager(), app(sha256: wrong))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path + ".part"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.hashesFile.path), "a rejected file is not recorded")
    }

    func testMatchingDeclaredHashPasses() async throws {
        serve(body)
        let events = try await run(manager(), app(sha256: sha(body).uppercased()))
        XCTAssertEqual(events.last, .finished(file: destination(), sha256: sha(body)))
    }

    func testChangedContentAtTheSameURLIsRefusedUnlessAllowed() async throws {
        serve(body)
        let first = manager()
        _ = try await run(first, app())
        try FileManager.default.removeItem(at: destination())

        let other = Data(body.reversed())
        serve(other)
        await expectFailure(.hashChanged(expected: sha(body), actual: sha(other))) {
            _ = try await run(first, app())
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))

        let events = try await run(first, app(), allowChangedHash: true)
        XCTAssertEqual(events.last, .finished(file: destination(), sha256: sha(other)))
        let record = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: paths.hashesFile))
        XCTAssertEqual(record[url.absoluteString], sha(other), "the override re-pins the new hash")
    }

    // MARK: Reuse

    func testACompleteFileMatchingTheRecordIsReusedWithoutATransfer() async throws {
        serve(body)
        let first = manager()
        _ = try await run(first, app())
        let before = StubURLProtocol.requests.count

        let events = try await run(first, app())
        XCTAssertEqual(StubURLProtocol.requests.count, before, "no second request")
        XCTAssertEqual(events.last, .finished(file: destination(), sha256: sha(body)))
    }

    func testAFileThatNoLongerMatchesTheRecordIsDownloadedAgain() async throws {
        serve(body)
        let first = manager()
        _ = try await run(first, app())
        try Data("tampered".utf8).write(to: destination())

        _ = try await run(first, app())
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        XCTAssertEqual(try Data(contentsOf: destination()), body)
    }

    func testAFileWithNoRecordIsNotTrusted() async throws {
        try paths.ensure()
        try Data("planted".utf8).write(to: destination())
        serve(body)
        _ = try await run(manager(), app())
        XCTAssertEqual(try Data(contentsOf: destination()), body)
    }

    // MARK: Cancel

    func testCancellingStopsTheTransferKeepsThePartAndALaterRunResumes() async throws {
        StubURLProtocol.handler = { [body] _ in
            .init(headers: ["Content-Length": "3000"], chunks: [body.prefix(1000)], hang: true)
        }
        let stream = manager().download(app().1, of: app().0)
        let sawProgress = expectation(description: "first progress")
        let consumer = Task {
            for try await event in stream {
                if case .progress = event { sawProgress.fulfill() }
            }
        }
        await fulfillment(of: [sawProgress], timeout: 5)
        consumer.cancel()
        _ = try? await consumer.value

        try await waitUntil { StubURLProtocol.stopCount > 0 }
        XCTAssertEqual(try Data(contentsOf: destination("com.example.app-1.0.ipa.part")), body.prefix(1000))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination().path))

        serve(body)
        _ = try await run(manager(), app())
        XCTAssertEqual(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=1000-")
        XCTAssertEqual(try Data(contentsOf: destination()), body)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out waiting for the transfer to stop") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: Failure shape

    func testFailuresHaveStableCodesAndActionableSentences() {
        let samples: [DownloadFailure] = [
            .blockedURL("x"), .sizeCapExceeded(limit: 1 << 30), .httpStatus(500),
            .incomplete(received: 1, expected: 2), .hashMismatch(expected: "a", actual: "b"),
            .hashChanged(expected: "a", actual: "b"), .hashRecordUnreadable("x"),
            .alreadyInProgress("x"), .network("x"), .disk("x"),
        ]
        XCTAssertEqual(Set(samples.map(\.code)).count, samples.count, "codes are unique")
        XCTAssertTrue(samples.allSatisfy { $0.code.hasPrefix("download.") && $0.message.hasSuffix(".") })
        XCTAssertEqual(DownloadFailure.hashChanged(expected: "a", actual: "b").code, "download.hash_changed")
    }
}
