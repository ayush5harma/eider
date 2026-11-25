import Foundation
import XCTest
@testable import EiderKit

/// Entries that share a bundle id within one source are one app; see `CatalogMerge`.
final class CatalogMergeTests: XCTestCase {
    private let sourceURL = URL(string: "https://example.com/repo.json")!

    private func entry(
        _ id: String, name: String = "App", version: String, date: String? = nil, notes: String? = nil,
        url: String? = nil, extra: String = ""
    ) -> String {
        let link = url ?? "https://cdn.example.com/\(id)-\(version).ipa"
        let when = date.map { #","date":"\#($0)""# } ?? ""
        let note = notes.map { #","localizedDescription":"\#($0)""# } ?? ""
        return #"{"name":"\#(name)","bundleIdentifier":"\#(id)"\#(extra),"versions":[{"version":"\#(version)","downloadURL":"\#(link)"\#(when)\#(note)}]}"#
    }

    private func parse(_ entries: [String]) throws -> CatalogSource {
        let json = #"{"name":"S","apps":[\#(entries.joined(separator: ","))]}"#
        return try SourceParser.parse(data: Data(json.utf8), from: sourceURL)
    }

    func testEntriesWithOneBundleIDBecomeOneAppWithEveryVersionNewestFirst() throws {
        let source = try parse([
            entry("com.a", version: "1.9"), entry("com.b", version: "1"),
            entry("com.a", version: "1.10"), entry("com.a", version: "1.2"),
        ])
        XCTAssertEqual(source.apps.map(\.bundleID), ["com.a", "com.b"], "at the first entry's position")
        XCTAssertEqual(source.apps[0].versions.map(\.version), ["1.10", "1.9", "1.2"])
        XCTAssertEqual(source.entryCount, 4)
        XCTAssertEqual(source.warnings, [], "merging is not a warning")
    }

    func testNothingMergedLeavesTheCountUnset() throws {
        let source = try parse([entry("com.a", version: "1"), entry("com.b", version: "1")])
        XCTAssertNil(source.entryCount)
        XCTAssertEqual(source.apps.count, 2)
    }

    func testAppFieldsComeFromTheEntryWithTheNewestVersionAndFallBackToTheFirstNonEmpty() throws {
        let source = try parse([
            entry("com.a", name: "Old Name", version: "1.0", extra: #","developerName":"Old Dev","subtitle":"Old sub","category":"games""#),
            entry("com.a", name: "New Name", version: "2.0", extra: #","subtitle":"New sub""#),
        ])
        let app = try XCTUnwrap(source.apps.first)
        XCTAssertEqual(app.name, "New Name")
        XCTAssertEqual(app.subtitle, "New sub")
        XCTAssertEqual(app.developerName, "Old Dev", "the newest entry has none, so the first that does")
        XCTAssertEqual(app.category, "games")
    }

    func testEachVersionKeepsItsOwnNotesAndAddress() throws {
        let source = try parse([
            entry("com.a", name: "One", version: "1.0", notes: "first notes", url: "https://cdn.example.com/a1.ipa"),
            entry("com.a", name: "Two", version: "2.0", notes: "second notes", url: "https://cdn.example.com/a2.ipa"),
        ])
        let versions = try XCTUnwrap(source.apps.first).versions
        XCTAssertEqual(versions.map(\.notes), ["second notes", "first notes"])
        XCTAssertEqual(versions.map(\.downloadURL.absoluteString), ["https://cdn.example.com/a2.ipa", "https://cdn.example.com/a1.ipa"])
    }

    func testTheSameVersionAtTheSameAddressIsListedOnce() throws {
        let source = try parse([
            entry("com.a", version: "1.0", notes: "kept"),
            entry("com.a", version: "1.0", notes: "dropped"),
            entry("com.a", version: "1.0", url: "https://mirror.example.com/a.ipa"),
        ])
        let versions = try XCTUnwrap(source.apps.first).versions
        XCTAssertEqual(versions.count, 2, "another address for the same version is another download")
        XCTAssertEqual(versions[0].notes, "kept")
    }

    /// Dates are the least reliable field (BlockerX 6.4.2 is dated after 6.5.3 in a real
    /// source), so they only break ties the version number leaves.
    func testVersionDecidesBeforeDateAndDateBreaksTies() throws {
        let source = try parse([
            entry("com.a", version: "6.4.2", date: "2026-07-12"),
            entry("com.a", version: "6.5.3", date: "2026-05-25"),
            entry("com.a", version: "nightly-a", date: "2026-09-01"),
            entry("com.a", version: "nightly-b", date: "2026-10-01"),
            entry("com.a", version: "abc1234"),
        ])
        XCTAssertEqual(
            source.apps[0].versions.map(\.version),
            ["6.5.3", "6.4.2", "nightly-b", "nightly-a", "abc1234"],
            "numeric first; labels by date, newest first; undated last")
    }

    func testDifferentSourcesStaySeparate() async throws {
        let fake = FakeFetch()
        let first = URL(string: "https://a.example.com/s.json")!
        let second = URL(string: "https://b.example.com/s.json")!
        let body = { (url: String) in #"{"name":"S","apps":[\#(self.entry("com.a", version: "1")),\#(self.entry("com.a", version: "2"))]}"# }
        fake.set(first, json: body("a"))
        fake.set(second, json: body("b"))
        let store = SourceStore(paths: try CatalogFixtures.temporaryHome(), fetch: fake.fetch)
        _ = try await store.add(url: first)
        _ = try await store.add(url: second)
        let apps = try await store.allApps()
        XCTAssertEqual(apps.map(\.sourceURL), [first, second])
        XCTAssertEqual(Set(apps.map(\.id)).count, 2)
    }

    func testPlayCoverDuplicatesMergeToo() throws {
        let json = #"""
        [{"bundleID":"com.p","name":"P","version":"1.0","link":"https://cdn.example.com/p1.ipa"},
         {"bundleID":"com.p","name":"P","version":"1.1","link":"https://cdn.example.com/p2.ipa"}]
        """#
        let source = try SourceParser.parse(data: Data(json.utf8), from: sourceURL)
        XCTAssertEqual(source.apps.count, 1)
        XCTAssertEqual(source.apps[0].versions.map(\.version), ["1.1", "1.0"])
    }

    func testMergingIsIdempotent() throws {
        let source = try parse([entry("com.a", version: "1"), entry("com.a", version: "2")])
        XCTAssertEqual(CatalogMerge.normalized(source), source)
    }

    // MARK: Row identity

    func testRowIdsAreUniqueAfterTheMerge() async throws {
        let fake = FakeFetch()
        let url = URL(string: "https://a.example.com/s.json")!
        let entries = (0..<20).map { entry("com.dup", name: "[untitled]", version: "1.\($0)") } + [entry("com.other", version: "1")]
        fake.set(url, json: #"{"name":"S","apps":[\#(entries.joined(separator: ","))]}"#)
        let store = SourceStore(paths: try CatalogFixtures.temporaryHome(), fetch: fake.fetch)
        _ = try await store.add(url: url)
        let ids = try await store.allApps().map(\.id)
        XCTAssertEqual(ids, ["\(url.absoluteString)|com.dup", "\(url.absoluteString)|com.other"])
    }

    /// A hand-edited file may list one address twice; ids must still not collide.
    func testIdsStayUniqueEvenWhenAFileListsOneAddressTwice() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        let app = CatalogApp(bundleID: "com.a", name: "A", versions: [CatalogVersion(version: "1", downloadURL: URL(string: "https://c.example.com/a.ipa")!)])
        let source = CatalogSource(url: sourceURL, format: .altStore, name: "S", apps: [app], fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        struct File: Encodable { var version = 1; var sources: [CatalogSource] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try paths.ensure()
        try encoder.encode(File(sources: [source, source])).write(to: paths.sourcesFile)

        let ids = try await SourceStore(paths: paths).allApps().map(\.id)
        XCTAssertEqual(ids, ["\(sourceURL.absoluteString)|com.a", "\(sourceURL.absoluteString)|com.a#2"])
    }

    // MARK: Persisted copies

    /// A sources.json written before merging holds one entry per version; loading it
    /// merges in memory, without a refresh, and leaves the file as it was until the next change.
    func testAnOldFileWithDuplicateEntriesIsMergedOnLoad() async throws {
        let paths = try CatalogFixtures.temporaryHome()
        func app(_ version: String) -> CatalogApp {
            CatalogApp(bundleID: "com.a", name: "A", versions: [CatalogVersion(version: version, downloadURL: URL(string: "https://c.example.com/\(version).ipa")!)])
        }
        let old = CatalogSource(
            url: sourceURL, format: .altStore, name: "S", apps: [app("1.9"), app("1.10")],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        struct File: Encodable { var version = 1; var sources: [CatalogSource] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try paths.ensure()
        try encoder.encode(File(sources: [old])).write(to: paths.sourcesFile)
        let before = try Data(contentsOf: paths.sourcesFile)

        let loaded = try await SourceStore(paths: paths).sources
        XCTAssertEqual(loaded.first?.apps.count, 1)
        XCTAssertEqual(loaded.first?.apps.first?.versions.map(\.version), ["1.10", "1.9"])
        XCTAssertEqual(loaded.first?.entryCount, 2)
        XCTAssertEqual(try Data(contentsOf: paths.sourcesFile), before, "loading does not write")
    }
}
