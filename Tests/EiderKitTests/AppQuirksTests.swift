import Foundation
import XCTest
@testable import EiderKit

/// The per-app quirk table: which apps get the quirks shim, and the rows the
/// installer writes into the bundle for the shim to apply.
final class AppQuirksTests: XCTestCase {
    func testYouTubeIsTheFirstRow() {
        let row = AppQuirks.all.first
        XCTAssertEqual(row?.bundleID, "com.google.ios.youtube")
        XCTAssertEqual(row?.className, "YTColdConfig")
        XCTAssertEqual(row?.selector, "mainAppCoreClientIos27SceneDelegateLaunchSequenceFixEnabled")
        XCTAssertEqual(row?.returns, true)
    }

    func testEveryRowIsWellFormed() {
        for row in AppQuirks.all {
            XCTAssertTrue(BundleIdentifier.isValid(row.bundleID), row.bundleID)
            XCTAssertTrue(AppQuirk.isPlainName(row.className), row.className)
            // A BOOL getter takes no arguments, so its selector has no colon.
            XCTAssertTrue(AppQuirk.isPlainName(row.selector), row.selector)
            XCTAssertFalse(row.why.isEmpty, row.selector)
        }
    }

    func testNoTwoRowsChangeTheSameMethodOfOneApp() {
        let keys = AppQuirks.all.map { "\($0.bundleID) \($0.className) \($0.selector)" }
        XCTAssertEqual(Set(keys).count, keys.count)
    }

    func testRowsAreChosenByExactBundleID() {
        XCTAssertFalse(AppQuirks.rows(for: "com.google.ios.youtube").isEmpty)
        for id in ["", "com.example.app", "com.google.ios.youtubemusic", "COM.GOOGLE.IOS.YOUTUBE"] {
            XCTAssertTrue(AppQuirks.rows(for: id).isEmpty, id)
        }
    }

    func testTheLinkerAsksTheTable() {
        XCTAssertEqual(ShimLinker.quirkBundleIDs, Set(AppQuirks.all.map(\.bundleID)))
    }

    func testRowsAreWrittenAsThePlistTheShimReads() throws {
        let app = try temporaryDirectory()
        let url = try AppQuirks.write(AppQuirks.rows(for: "com.google.ios.youtube"), into: app)
        XCTAssertEqual(url.lastPathComponent, "EiderQuirks.plist")
        let rows = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["class"] as? String, "YTColdConfig")
        XCTAssertEqual(rows[0]["selector"] as? String, "mainAppCoreClientIos27SceneDelegateLaunchSequenceFixEnabled")
        XCTAssertEqual(rows[0]["returns"] as? Bool, true)
        XCTAssertEqual(Set(rows[0].keys), ["class", "selector", "returns"])
    }

    /// An IPA may ship a file or a symlink by that name; the installer's rows replace it.
    func testAFileOrSymlinkTheIPAShippedIsReplacedNotFollowed() throws {
        let app = try temporaryDirectory()
        let outside = try temporaryDirectory().appendingPathComponent("target.plist")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("EiderQuirks.plist"), withDestinationURL: outside)
        let url = try AppQuirks.write(AppQuirks.rows(for: "com.google.ios.youtube"), into: app)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "outside")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: url.path))
        XCTAssertNotNil(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [Any])
    }

    func testPlainNamesAreObjectiveCIdentifiers() {
        for name in ["YTColdConfig", "_Private", "a1", "Module_Class"] { XCTAssertTrue(AppQuirk.isPlainName(name), name) }
        for name in ["", "1abc", "has space", "sel:", "a.b", "a/b", String(repeating: "a", count: 300)] {
            XCTAssertFalse(AppQuirk.isPlainName(name), name)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eider-quirks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
