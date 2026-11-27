import Foundation
import XCTest
@testable import EiderCore
@testable import EiderKit

/// A bundle id is not an app's identity in a tweak source: fastsign.dev lists 211
/// entries under com.google.ios.youtube as 152 different apps. Only entries with the
/// same bundle id AND the same name are one app (`CatalogMerge`).
final class CatalogSameNameTests: XCTestCase {
    private let sourceURL = URL(string: "https://example.com/repo.json")!
    private let youtube = "com.google.ios.youtube"

    private func entry(_ id: String, name: String, version: String) -> String {
        let link = "https://cdn.example.com/\(abs(name.hashValue))-\(version).ipa"
        return #"{"name":"\#(name)","bundleIdentifier":"\#(id)","versions":[{"version":"\#(version)","downloadURL":"\#(link)"}]}"#
    }

    private func parse(_ entries: [String]) throws -> CatalogSource {
        try SourceParser.parse(data: Data(#"{"name":"S","apps":[\#(entries.joined(separator: ","))]}"#.utf8), from: sourceURL)
    }

    private var tweakSource: [String] {
        [
            entry(youtube, name: "YouTubeOLED", version: "20.1"),
            entry(youtube, name: "YTKACE (1.1.9) - Bonus Tweaks (IPAVault)", version: "21.47.6"),
            entry(youtube, name: "YouTube (YTKACE 1.1.9)", version: "21.47.6"),
            entry(youtube, name: "YouTubeOLED", version: "20.2"),
        ]
    }

    // MARK: Merging

    func testDifferentNamesUnderOneBundleIDStaySeparateApps() throws {
        let source = try parse(tweakSource)
        XCTAssertEqual(source.apps.map(\.name), ["YouTubeOLED", "YTKACE (1.1.9) - Bonus Tweaks (IPAVault)", "YouTube (YTKACE 1.1.9)"])
        XCTAssertEqual(source.apps[0].versions.map(\.version), ["20.2", "20.1"], "the same name still merges its versions")
        XCTAssertEqual(source.entryCount, 4)
    }

    func testTenListingsOfOneBlockerAreStillOneApp() throws {
        let spellings = ["1Blocker", "1blocker", " 1Blocker ", "1Blocker", "1Blocker", "1Blocker", "1BLOCKER", "1Blocker", "1Blocker", "1Blocker"]
        let source = try parse(spellings.enumerated().map { entry("com.blockerx.blocker", name: $1, version: "1.\($0)") })
        XCTAssertEqual(source.apps.count, 1)
        XCTAssertEqual(source.apps[0].versions.count, 10)
    }

    func testNamesComparedTrimmedCollapsedAndCaseInsensitive() {
        XCTAssertEqual(CatalogApp.nameKey("  My   App "), CatalogApp.nameKey("my app"))
        XCTAssertNotEqual(CatalogApp.nameKey("My App"), CatalogApp.nameKey("My App 2"))
    }

    func testAFreshParseCarriesTheMergeRule() throws {
        XCTAssertEqual(try parse(tweakSource).mergeRule, CatalogMerge.rule)
        XCTAssertFalse(try parse(tweakSource).isOverMerged)
        XCTAssertTrue(CatalogSource(url: sourceURL, format: .altStore, name: "old").isOverMerged)
    }

    // MARK: Row identity

    func testRowIdsKeepTheOldFormWhenABundleIDHasOneNameAndAddTheNameWhenItHasSeveral() throws {
        let source = try parse(tweakSource + [entry("com.other", name: "Other", version: "1")])
        let ids = SourcedApp.entries(of: source).map(\.id)
        let base = sourceURL.absoluteString
        XCTAssertEqual(ids, [
            "\(base)|\(youtube)|youtubeoled",
            "\(base)|\(youtube)|ytkace (1.1.9) - bonus tweaks (ipavault)",
            "\(base)|\(youtube)|youtube (ytkace 1.1.9)",
            "\(base)|com.other",
        ])
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testAllAppsServesTheEntryIdsAndALookupByTheFullIdFindsOneEntry() async throws {
        let fake = FakeFetch()
        fake.set(sourceURL, json: #"{"name":"S","apps":[\#(tweakSource.joined(separator: ","))]}"#)
        let paths = try CatalogFixtures.temporaryHome()
        let operations = AppOperations(paths: paths, sources: SourceStore(paths: paths, fetch: fake.fetch))
        _ = try await operations.sources.add(url: sourceURL)
        let all = try await operations.sources.allApps()
        XCTAssertEqual(all.count, 3)

        let target = all[1]
        let found = try await operations.catalogEntry(matching: target.id)
        XCTAssertEqual(found?.app.name, "YTKACE (1.1.9) - Bonus Tweaks (IPAVault)")
    }

    func testABundleIDThatSeveralAppsShareIsAmbiguousAndListsTheCandidates() async throws {
        let fake = FakeFetch()
        fake.set(sourceURL, json: #"{"name":"S","apps":[\#((tweakSource + [entry("com.other", name: "Other", version: "1")]).joined(separator: ","))]}"#)
        let paths = try CatalogFixtures.temporaryHome()
        let operations = AppOperations(paths: paths, sources: SourceStore(paths: paths, fetch: fake.fetch))
        _ = try await operations.sources.add(url: sourceURL)

        do {
            _ = try await operations.catalogEntry(matching: youtube)
            XCTFail("expected an ambiguity")
        } catch let failure as OperationFailure {
            XCTAssertEqual(failure.code, "operations.ambiguous_entry")
            XCTAssertTrue(failure.message.contains("YouTubeOLED 20.2"), failure.message)
            XCTAssertTrue(failure.message.contains("YTKACE (1.1.9) - Bonus Tweaks (IPAVault) 21.47.6"), failure.message)
            XCTAssertTrue(failure.message.contains("\(sourceURL.absoluteString)|\(youtube)|youtubeoled"), "each line ends with the id to pass")
        }
        let single = try await operations.catalogEntry(matching: "com.other")
        XCTAssertEqual(single?.app.name, "Other", "an id with one app is unchanged")
        let none = try await operations.catalogEntry(matching: "com.missing")
        XCTAssertNil(none)
    }

    // MARK: Updates

    private func installed(name: String, origin: InstallOrigin?, source: URL? = nil, version: String = "1.0") -> InstalledApp {
        InstalledApp(
            bundleID: youtube, name: name, version: version, build: "1", path: URL(fileURLWithPath: "/tmp/Y.app"),
            sourceURL: source, origin: origin, options: InstallOptions())
    }

    private func catalog(_ names: [(String, String)], source: URL? = nil) throws -> [SourcedApp] {
        let json = #"{"name":"S","apps":[\#(names.map { entry(youtube, name: $0.0, version: $0.1) }.joined(separator: ","))]}"#
        let parsed = try SourceParser.parse(data: Data(json.utf8), from: source ?? sourceURL)
        return SourcedApp.entries(of: parsed)
    }

    func testAnInstalledYTKACEIsOfferedYTKACEAndNeverYouTubeOLED() throws {
        let entries = try catalog([("YouTubeOLED", "99.0"), ("YTKACE", "21.47.6")])
        let app = installed(name: "YouTube", origin: InstallOrigin(sourceURL: sourceURL, entryID: youtube, entryName: "YTKACE"))
        let update = try XCTUnwrap(UpdateChecker.update(for: app, in: entries))
        XCTAssertEqual(update.app.name, "YTKACE")
        XCTAssertEqual(update.version.version, "21.47.6")
    }

    func testNothingIsOfferedWhenTheInstalledEntryIsGoneAndTheSourceListsOtherAppsUnderTheSameID() throws {
        let entries = try catalog([("YouTubeOLED", "99.0"), ("YouMod", "98.0")])
        let renamed = installed(name: "YouTube", origin: InstallOrigin(sourceURL: sourceURL, entryID: youtube, entryName: "YTKACE"))
        XCTAssertNil(UpdateChecker.update(for: renamed, in: entries))
        let unknown = installed(name: "YouTube", origin: nil)
        XCTAssertNil(UpdateChecker.update(for: unknown, in: entries), "the cross-source fallback needs a single name")
    }

    func testTheBundleIDFallbackStillAppliesWhereASourceListsOneName() throws {
        let other = URL(string: "https://other.example.com/repo.json")!
        let entries = try catalog([("YouTubeOLED", "99.0"), ("YouMod", "98.0")]) + (try catalog([("YouTube", "5.0")], source: other))
        let app = installed(name: "YouTube", origin: nil)
        XCTAssertEqual(UpdateChecker.update(for: app, in: entries)?.sourceURL, other)
    }

    func testAnOriginWrittenBeforeNamesWereRecordedFallsBackToTheInstalledName() throws {
        let entries = try catalog([("YouTubeOLED", "99.0"), ("YTKACE", "21.47.6")])
        let legacy = installed(name: "ytkace", origin: InstallOrigin(sourceURL: sourceURL, entryID: youtube))
        XCTAssertEqual(UpdateChecker.update(for: legacy, in: entries)?.app.name, "YTKACE")
        let unmatched = installed(name: "YouTube", origin: InstallOrigin(sourceURL: sourceURL, entryID: youtube))
        XCTAssertNil(UpdateChecker.update(for: unmatched, in: entries))
    }

    func testAnOriginOnDiskWithoutAnEntryNameStillDecodes() throws {
        let json = #"{"sourceURL":"https://example.com/repo.json","entryID":"com.a"}"#
        let origin = try JSONDecoder().decode(InstallOrigin.self, from: Data(json.utf8))
        XCTAssertNil(origin.entryName)
    }

    // MARK: Saved copies and the launch refresh

    private func writeOldFormatFile(_ paths: EiderPaths, fetchedAt: Date) throws {
        // The shape 0.1.2 to 0.1.6 wrote: one merged app per bundle id, no mergeRule.
        let merged = CatalogApp(bundleID: youtube, name: "YouTubeOLED", versions: [CatalogVersion(version: "20.2", downloadURL: URL(string: "https://cdn.example.com/a.ipa")!)])
        let old = CatalogSource(url: sourceURL, format: .altStore, name: "S", apps: [merged], fetchedAt: fetchedAt, entryCount: 4)
        struct File: Encodable { var version = 1; var sources: [CatalogSource] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try paths.ensure()
        try encoder.encode(File(sources: [old])).write(to: paths.sourcesFile)
    }

    @MainActor
    func testASourceSavedUnderTheOldRuleIsRefetchedAtLaunchEvenWhenItIsFresh() async throws {
        let fake = FakeFetch()
        fake.set(sourceURL, json: #"{"name":"S","apps":[\#(tweakSource.joined(separator: ","))]}"#)
        let (model, paths) = try AppModelFixtures.liveModel(fetch: fake)
        try writeOldFormatFile(paths, fetchedAt: Date())
        await model.reload()
        XCTAssertTrue(try XCTUnwrap(model.sources.first).isOverMerged, "flagged on load")
        XCTAssertEqual(model.catalog.count, 1)

        await model.refreshStaleSources()
        XCTAssertEqual(fake.count(sourceURL), 1, "refetched right away, not after six hours")
        XCTAssertEqual(model.catalog.count, 3)
        XCTAssertFalse(try XCTUnwrap(model.sources.first).isOverMerged)

        await model.refreshStaleSources()
        XCTAssertEqual(fake.count(sourceURL), 1, "a current copy is left alone until it ages")
    }
}
