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
}
