import Foundation
import XCTest
@testable import EiderKit

/// Finding 10: force and resetData are per invocation, not part of the record.
final class SecurityRecordedOptionsTests: XCTestCase {
    func testTheLibraryNeverRecordsForceResetDataOrTheExpectedID() async throws {
        let scratch = try EngineScratch()
        let paths = EiderPaths(home: scratch.url("home"))
        let store = LibraryStore(paths: paths)
        let options = InstallOptions(macIdiom: true, resetData: true, force: true, expectedBundleID: "com.x")
        let app = InstalledApp(bundleID: "com.x", name: "X", version: "1", build: "1", path: scratch.url("X.app"), options: options)
        XCTAssertFalse(app.options.force)
        XCTAssertFalse(app.options.resetData)
        XCTAssertNil(app.options.expectedBundleID)
        XCTAssertTrue(app.options.macIdiom, "what describes the install is kept")

        try await store.record(app)
        let text = try String(contentsOf: paths.libraryFile)
        XCTAssertTrue(text.contains(#""force" : false"#) && text.contains(#""resetData" : false"#), text)
        XCTAssertFalse(text.contains("expectedBundleID"))
        let read = try await store.app(bundleID: "com.x")
        XCTAssertEqual(read?.options.force, false)
        XCTAssertEqual(read?.options.resetData, false)
    }
}
