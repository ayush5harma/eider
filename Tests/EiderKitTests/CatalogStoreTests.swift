import XCTest
@testable import EiderKit

/// Fetch double: a table of canned documents and failures, with call counts.
final class FakeFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var documents: [URL: Result<Data, Error>] = [:]
    private var calls: [URL: Int] = [:]

    func set(_ url: URL, json: String) { lock.withLock { documents[url] = .success(Data(json.utf8)) } }
    func set(_ url: URL, error: Error) { lock.withLock { documents[url] = .failure(error) } }
    func count(_ url: URL) -> Int { lock.withLock { calls[url] ?? 0 } }

    var fetch: SourceFetch {
        { [self] url in
            let outcome = lock.withLock { () -> Result<Data, Error>? in
                calls[url, default: 0] += 1
                return documents[url]
            }
            guard let outcome else { throw CatalogFailure.fetchFailed("no such document") }
            return try outcome.get()
        }
    }
}

final class CatalogStoreTests: XCTestCase {
    private let urlA = URL(string: "https://a.example.com/source.json")!
    private let urlB = URL(string: "https://b.example.com/source.json")!

    private func altStore(name: String, apps: [(String, String)]) -> String {
        let entries = apps.map {
            #"{"name":"\#($0.1)","bundleIdentifier":"\#($0.0)","versions":[{"version":"1","downloadURL":"https://cdn.example.com/\#($0.0).ipa"}]}"#
        }.joined(separator: ",")
        return #"{"name":"\#(name)","apps":[\#(entries)]}"#
    }

    func testMissingAndEmptyFilesAreAnEmptyList() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        let store = SourceStore(paths: paths, fetch: FakeFetch().fetch)
        let initial = try await store.sources
        XCTAssertEqual(initial, [])

        try paths.ensure()
        try Data().write(to: paths.sourcesFile)
        let afterEmpty = try await SourceStore(paths: paths, fetch: FakeFetch().fetch).sources
        XCTAssertEqual(afterEmpty, [])
    }

    func testSourcesPersistAcrossInstances() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        let fake = FakeFetch()
        fake.set(urlA, json: altStore(name: "A", apps: [("com.a", "App A")]))
        let first = SourceStore(paths: paths, fetch: fake.fetch)
        let added = try await first.add(url: urlA)

        let second = SourceStore(paths: paths, fetch: fake.fetch)
        let reloaded = try await second.sources
        XCTAssertEqual(reloaded, [added], "round trip is exact, dates included")
        XCTAssertEqual(reloaded.first?.apps.first?.bundleID, "com.a")
    }

    func testAddingAKnownURLRefreshesInPlace() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        let fake = FakeFetch()
        fake.set(urlA, json: altStore(name: "A", apps: [("com.a", "One")]))
        fake.set(urlB, json: altStore(name: "B", apps: [("com.b", "Two")]))
        let store = SourceStore(paths: paths, fetch: fake.fetch)
        _ = try await store.add(url: urlA)
        _ = try await store.add(url: urlB)

        fake.set(urlA, json: altStore(name: "A renamed", apps: [("com.a", "One"), ("com.a2", "More")]))
        _ = try await store.add(url: urlA)

        let sources = try await store.sources
        XCTAssertEqual(sources.map(\.url), [urlA, urlB], "no duplicate, position kept")
        XCTAssertEqual(sources.first?.name, "A renamed")
        XCTAssertEqual(sources.first?.apps.count, 2)
    }

    func testFailedAddPersistsNothing() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        let fake = FakeFetch()
        fake.set(urlA, json: "not json")
        let store = SourceStore(paths: paths, fetch: fake.fetch)
        do {
            _ = try await store.add(url: urlA)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CatalogFailure, .notJSON)
        }
        let remaining = try await store.sources
        XCTAssertEqual(remaining, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sourcesFile.path))
    }

    func testAddRefusesAnAddressThePolicyBlocksWithoutFetching() async throws {
        let fake = FakeFetch()
        let store = SourceStore(paths: try CatalogFixtures.temporaryHome(), fetch: fake.fetch)
        let insecure = URL(string: "http://example.com/source.json")!
        do {
            _ = try await store.add(url: insecure)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? CatalogFailure)?.code, "catalog.blocked_url")
        }
        XCTAssertEqual(fake.count(insecure), 0)
    }

    func testRemoveAndUnknownSource() async throws {
        let fake = FakeFetch()
        fake.set(urlA, json: altStore(name: "A", apps: [("com.a", "One")]))
        let store = SourceStore(paths: try CatalogFixtures.temporaryHome(), fetch: fake.fetch)
        _ = try await store.add(url: urlA)
        try await store.remove(url: urlA)
        let afterRemove = try await store.sources
        XCTAssertEqual(afterRemove, [])
        do {
            try await store.remove(url: urlA)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CatalogFailure, .unknownSource(urlA))
        }
        do {
            _ = try await store.refresh(url: urlB)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CatalogFailure, .unknownSource(urlB))
        }
    }

    func testRefreshAllReportsEachSourceAndKeepsTheOldCopyOfAFailure() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        let fake = FakeFetch()
        fake.set(urlA, json: altStore(name: "A", apps: [("com.a", "One")]))
        fake.set(urlB, json: altStore(name: "B", apps: [("com.b", "Two")]))
        let store = SourceStore(paths: paths, fetch: fake.fetch)
        _ = try await store.add(url: urlA)
        _ = try await store.add(url: urlB)

        fake.set(urlA, error: CatalogFailure.fetchFailed("offline"))
        fake.set(urlB, json: altStore(name: "B2", apps: [("com.b", "Two")]))
        let results = try await store.refreshAll()

        XCTAssertEqual(results.map(\.url), [urlA, urlB])
        XCTAssertThrowsError(try results[0].result.get())
        XCTAssertEqual(try results[1].result.get().name, "B2")
        let names = try await store.sources.map(\.name)
        XCTAssertEqual(names, ["A", "B2"])
        let persisted = try await SourceStore(paths: paths, fetch: fake.fetch).sources.map(\.name)
        XCTAssertEqual(persisted, ["A", "B2"])
    }

    func testAllAppsKeepsTheSameBundleIDFromTwoSourcesAsTwoEntries() async throws {
        let fake = FakeFetch()
        fake.set(urlA, json: altStore(name: "A", apps: [("com.same", "Same")]))
        fake.set(urlB, json: altStore(name: "B", apps: [("com.same", "Same"), ("com.only", "Only")]))
        let store = SourceStore(paths: try CatalogFixtures.temporaryHome(), fetch: fake.fetch)
        _ = try await store.add(url: urlA)
        _ = try await store.add(url: urlB)

        let apps = try await store.allApps()
        XCTAssertEqual(apps.map(\.app.bundleID), ["com.same", "com.same", "com.only"])
        XCTAssertEqual(apps.map(\.sourceURL), [urlA, urlB, urlB])
    }

    func testUnreadableFileIsReportedNotOverwritten() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        try paths.ensure()
        try Data("{ broken".utf8).write(to: paths.sourcesFile)
        let store = SourceStore(paths: paths, fetch: FakeFetch().fetch)
        do {
            _ = try await store.sources
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? CatalogFailure)?.code, "catalog.store_unreadable")
        }
        XCTAssertEqual(try String(contentsOf: paths.sourcesFile, encoding: .utf8), "{ broken")
    }
}

final class CatalogDeepLinkTests: XCTestCase {
    private func parse(_ text: String) -> DeepLink? {
        URL(string: text).flatMap(DeepLink.parse)
    }

    func testAddSourceAndInstall() {
        XCTAssertEqual(parse("eider://source/https://example.com/repo.json"),
                       .addSource(URL(string: "https://example.com/repo.json")!))
        XCTAssertEqual(parse("eider://install/https://example.com/app.ipa"),
                       .install(URL(string: "https://example.com/app.ipa")!))
    }

    func testQueryAndPercentEncodedInnerURLs() {
        XCTAssertEqual(parse("eider://source/https://example.com/repo.json?token=1&x=2"),
                       .addSource(URL(string: "https://example.com/repo.json?token=1&x=2")!))
        XCTAssertEqual(parse("eider://source/https%3A%2F%2Fexample.com%2Frepo.json"),
                       .addSource(URL(string: "https://example.com/repo.json")!))
    }

    func testPolicyAppliesToTheInnerURL() {
        XCTAssertNil(parse("eider://source/http://example.com/repo.json"))
        XCTAssertNil(parse("eider://install/file:///tmp/a.ipa"), "a link must never reach a local file")
        XCTAssertNil(parse("eider://install/javascript:alert(1)"))
        XCTAssertEqual(parse("eider://source/http://localhost:8000/repo.json"),
                       .addSource(URL(string: "http://localhost:8000/repo.json")!))
    }

    func testOtherLinksAreIgnored() {
        XCTAssertNil(parse("https://example.com/repo.json"))
        XCTAssertNil(parse("eider://other/https://example.com/x"))
        XCTAssertNil(parse("eider://source"))
        XCTAssertNil(parse("eider://source/"))
    }
}

final class CatalogFetcherTests: XCTestCase {
    private let url = URL(string: "https://example.com/source.json")!

    override func setUp() { StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset() }

    private func fetch(_ limit: Int64 = 1024) async throws -> Data {
        try await SourceFetcher.fetch(url, configuration: StubURLProtocol.configuration(), maxBytes: limit)
    }

    func testReturnsTheBody() async throws {
        StubURLProtocol.handler = { _ in .init(chunks: [Data("{}".utf8)]) }
        let body = try await fetch()
        XCTAssertEqual(body, Data("{}".utf8))
    }

    func testRefusesAnOversizeContentLength() async {
        StubURLProtocol.handler = { _ in .init(headers: ["Content-Length": "5000"], chunks: []) }
        do {
            _ = try await fetch()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CatalogFailure, .tooLarge(limit: 1024))
        }
    }

    func testRefusesAnOversizeBodyWhoseLengthWasUnderstated() async {
        StubURLProtocol.handler = { _ in
            .init(headers: ["Content-Length": "10"], chunks: [Data(count: 600), Data(count: 600)])
        }
        do {
            _ = try await fetch()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CatalogFailure, .tooLarge(limit: 1024))
        }
    }

    func testNonSuccessStatusFails() async {
        StubURLProtocol.handler = { _ in .init(status: 404) }
        do {
            _ = try await fetch()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? CatalogFailure)?.code, "catalog.fetch_failed")
        }
    }

    func testRedirectToPlainHTTPIsRefused() async {
        StubURLProtocol.handler = { _ in .init(status: 302, redirectTo: URL(string: "http://evil.example.com/x")!) }
        do {
            _ = try await fetch()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual((error as? CatalogFailure)?.code, "catalog.blocked_url")
        }
    }

    func testFileURLIsReadAndCapped() async throws {
        let directory = try CatalogFixtures.temporaryHome().home
        let file = directory.appendingPathComponent("source.json")
        try Data(count: 2000).write(to: file)
        do {
            _ = try await SourceFetcher.fetch(file, configuration: .ephemeral, maxBytes: 1024)
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? CatalogFailure, .tooLarge(limit: 1024))
        }
        let body = try await SourceFetcher.fetch(file, configuration: .ephemeral, maxBytes: 4096)
        XCTAssertEqual(body.count, 2000)
    }
}
