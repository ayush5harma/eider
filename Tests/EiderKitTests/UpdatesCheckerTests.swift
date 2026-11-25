import Foundation
import XCTest
@testable import EiderKit

final class UpdatesCheckerTests: XCTestCase {
    private let sourceA = URL(string: "https://a.example.com/s.json")!
    private let sourceB = URL(string: "https://b.example.com/s.json")!

    private func installed(_ version: String, build: String = "1", from source: URL? = nil, id: String = "com.x") -> InstalledApp {
        InstalledApp(
            bundleID: id, name: "X", version: version, build: build,
            path: URL(fileURLWithPath: "/tmp/X.app"), sourceURL: source, options: InstallOptions()
        )
    }

    private func catalog(_ source: URL, _ versions: [(String, String?)], id: String = "com.x") -> SourcedApp {
        let list = versions.map {
            CatalogVersion(version: $0.0, build: $0.1, downloadURL: URL(string: "https://cdn.example.com/\(id)-\($0.0).ipa")!)
        }
        return SourcedApp(
            source: CatalogSource(url: source, format: .altStore, name: source.host ?? "s"),
            app: CatalogApp(bundleID: id, name: "X", versions: list)
        )
    }

    // MARK: Comparison

    func testComponentsCompareNumericallyNotAsText() {
        XCTAssertEqual(AppVersion.compare("1.10", "1.9"), .orderedDescending)
        XCTAssertEqual(AppVersion.compare("2", "10"), .orderedAscending)
        XCTAssertEqual(AppVersion.compare("1.2.3", "1.2.3"), .orderedSame)
    }

    func testMissingComponentsCountAsZero() {
        XCTAssertEqual(AppVersion.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertEqual(AppVersion.compare("1.0.1", "1.0"), .orderedDescending)
    }

    func testNonNumericSuffixesStillOrderStably() {
        XCTAssertEqual(AppVersion.compare("1.0.0", "1.0.0-beta"), .orderedDescending, "a release is newer than its prerelease")
        XCTAssertEqual(AppVersion.compare("1.0-beta2", "1.0-beta10"), .orderedAscending)
        XCTAssertEqual(AppVersion.compare("v1.2", "1.2"), .orderedSame)
    }

    func testWhatIsDottedNumeric() {
        for text in ["1", "1.2", "1.2.3", "v1.2", "1.2-beta", "1.0b2", "3.8.14 (5)", "2026.11.22"] {
            XCTAssertTrue(AppVersion.isDottedNumeric(text), text)
        }
        for text in ["8b6e503", "nightly", "beta", "abc1234", "", "v", "2a", "1a"] {
            XCTAssertFalse(AppVersion.isDottedNumeric(text), text)
        }
    }

    /// A commit hash that starts with a digit used to read as version 8.
    func testAHashOrLabelNeverOutranksANumber() {
        XCTAssertEqual(AppVersion.compare("8b6e503", "3.8.14"), .orderedAscending)
        XCTAssertEqual(AppVersion.compare("3.8.14", "8b6e503"), .orderedDescending)
        XCTAssertEqual(AppVersion.compare("nightly", "0.0.1"), .orderedAscending)
        XCTAssertEqual(AppVersion.compare("8b6e503", "9f00d11"), .orderedSame, "no order between two hashes")
        XCTAssertFalse(AppVersion.isNewer(version: "8b6e503", build: nil, than: "3.8.14", build: nil))
    }

    func testLiveContainerHashEntryIsNotOfferedAsAnUpdate() {
        // com.kdt.livecontainer 3.8.14 installed; the source also lists a hash-named build.
        let id = "com.kdt.livecontainer"
        let entry = catalog(sourceA, [("3.8.14", nil), ("8b6e503", nil)], id: id)
        XCTAssertTrue(UpdateChecker.updates(installed: [installed("3.8.14", from: sourceA, id: id)], catalog: [entry]).isEmpty)
        XCTAssertEqual(UpdateChecker.newestVersion(of: entry.app)?.version, "3.8.14")

        // The unmerged form, as an old sources.json holds it: two entries, hash listed last.
        let split = [catalog(sourceA, [("3.8.14", nil)], id: id), catalog(sourceA, [("8b6e503", nil)], id: id)]
        XCTAssertTrue(UpdateChecker.updates(installed: [installed("3.8.14", from: sourceA, id: id)], catalog: split).isEmpty)
        XCTAssertEqual(UpdateChecker.updates(installed: [installed("3.8.0", from: sourceA, id: id)], catalog: split).first?.version.version, "3.8.14")
    }

    func testNewestAmongLabelsFollowsTheDateThenSourceOrder() {
        func version(_ text: String, _ date: Date?) -> CatalogVersion {
            CatalogVersion(version: text, date: date, downloadURL: URL(string: "https://cdn.example.com/\(text).ipa")!)
        }
        let dated = CatalogApp(bundleID: "com.x", name: "X", versions: [version("beta", .utc(2026, 1, 1)), version("nightly", .utc(2026, 3, 1))])
        XCTAssertEqual(UpdateChecker.newestVersion(of: dated)?.version, "nightly")
        let undated = CatalogApp(bundleID: "com.x", name: "X", versions: [version("beta", nil), version("nightly", nil)])
        XCTAssertEqual(UpdateChecker.newestVersion(of: undated)?.version, "beta", "source order")
    }

    func testBuildDecidesOnlyWhenVersionsAreEqual() {
        XCTAssertTrue(AppVersion.isNewer(version: "1.0", build: "10", than: "1.0", build: "9"))
        XCTAssertFalse(AppVersion.isNewer(version: "1.0", build: "9", than: "1.0", build: "10"))
        XCTAssertTrue(AppVersion.isNewer(version: "1.1", build: "1", than: "1.0", build: "99"))
        XCTAssertFalse(AppVersion.isNewer(version: "1.0", build: nil, than: "1.0", build: "5"))
        XCTAssertFalse(AppVersion.isNewer(version: "1.0", build: "5", than: "1.0", build: ""))
    }

    func testEqualVersionsAreNeverAnUpdate() {
        XCTAssertFalse(AppVersion.isNewer(version: "2.0", build: "3", than: "2.0", build: "3"))
        XCTAssertFalse(AppVersion.isNewer(version: "2.0", build: nil, than: "2.0", build: nil))
    }

    // MARK: Checker

    func testReportsTheNewestVersionAsAnUpdate() {
        let updates = UpdateChecker.updates(installed: [installed("1.9")], catalog: [catalog(sourceA, [("1.10", nil), ("1.9", nil)])])
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.version.version, "1.10")
        XCTAssertEqual(updates.first?.sourceURL, sourceA)
    }

    func testNoUpdateWhenEqualOrOlder() {
        XCTAssertTrue(UpdateChecker.updates(installed: [installed("1.10")], catalog: [catalog(sourceA, [("1.10", nil)])]).isEmpty)
        XCTAssertTrue(UpdateChecker.updates(installed: [installed("2.0")], catalog: [catalog(sourceA, [("1.10", nil)])]).isEmpty)
    }

    func testNewestIsFoundEvenIfTheSourceListsOldestFirst() {
        let updates = UpdateChecker.updates(installed: [installed("1.0")], catalog: [catalog(sourceA, [("1.1", nil), ("1.3", nil), ("1.2", nil)])])
        XCTAssertEqual(updates.first?.version.version, "1.3")
    }

    func testPrefersTheSourceTheAppWasInstalledFrom() {
        let updates = UpdateChecker.updates(
            installed: [installed("1.0", from: sourceA)],
            catalog: [catalog(sourceB, [("9.0", nil)]), catalog(sourceA, [("1.1", nil)])]
        )
        XCTAssertEqual(updates.first?.sourceURL, sourceA, "another source's newer build is not silently preferred")
        XCTAssertEqual(updates.first?.version.version, "1.1")
    }

    func testFallsBackToTheNewestAcrossSourcesWhenTheOriginIsGoneOrUnknown() {
        let catalogs = [catalog(sourceA, [("1.1", nil)]), catalog(sourceB, [("1.2", nil)])]
        XCTAssertEqual(UpdateChecker.updates(installed: [installed("1.0")], catalog: catalogs).first?.sourceURL, sourceB)
        let gone = URL(string: "https://gone.example.com/s.json")!
        XCTAssertEqual(UpdateChecker.updates(installed: [installed("1.0", from: gone)], catalog: catalogs).first?.sourceURL, sourceB)
    }

    func testOriginSourceThatNoLongerOffersAnUpdateDoesNotFallBackElsewhere() {
        let updates = UpdateChecker.updates(
            installed: [installed("1.0", from: sourceA)],
            catalog: [catalog(sourceA, [("1.0", nil)]), catalog(sourceB, [("5.0", nil)])]
        )
        XCTAssertTrue(updates.isEmpty)
    }

    func testOnlyMatchingBundleIdsAreConsidered() {
        let updates = UpdateChecker.updates(installed: [installed("1.0")], catalog: [catalog(sourceA, [("2.0", nil)], id: "com.other")])
        XCTAssertTrue(updates.isEmpty)
    }

    func testBuildNumberUpdatesAnAppWithTheSameVersion() {
        let updates = UpdateChecker.updates(installed: [installed("1.0", build: "4")], catalog: [catalog(sourceA, [("1.0", "5")])])
        XCTAssertEqual(updates.count, 1)
    }

    /// The batch check indexes the catalog once; it must answer exactly as asking
    /// for each app on its own does, ties between sources included.
    func testTheBatchCheckAgreesWithThePerAppCheck() {
        let ids = ["com.a", "com.b", "com.c", "com.d"]
        let catalogue = ids.flatMap { id in
            [catalog(sourceA, [("2.0", "1")], id: id), catalog(sourceB, [("2.0", "1"), ("3.0", "1")], id: id)]
        } + [catalog(sourceA, [("9.0", "1")], id: "com.other")]
        let library = [
            installed("1.0", from: sourceA, id: "com.a"), installed("1.0", from: nil, id: "com.b"),
            installed("5.0", from: sourceB, id: "com.c"), installed("1.0", from: sourceB, id: "com.d"),
            installed("1.0", id: "com.missing"),
        ]
        let batch = UpdateChecker.updates(installed: library, catalog: catalogue)
        let single = library.compactMap { UpdateChecker.update(for: $0, in: catalogue) }
        XCTAssertEqual(batch, single)
        XCTAssertEqual(batch.map(\.installed.bundleID), ["com.a", "com.b", "com.d"])
        XCTAssertEqual(batch.map(\.sourceURL), [sourceA, sourceB, sourceB], "origin first, otherwise the newest; ties keep catalog order")
    }
}
