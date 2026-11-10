import Foundation
import XCTest
@testable import EiderKit

/// Finding 2: "." used to pass the bundle-id check and, as a path component,
/// named ~/Library/Containers itself.
final class SecurityBundleIDTests: XCTestCase {
    func testValidatorAcceptsReverseDNSAndRefusesPathShapes() {
        for good in ["com.example.App-1_x", "a", "direct-0a1b2c3d4e5f", "9lives.app", "A.B"] {
            XCTAssertTrue(BundleIdentifier.isValid(good), good)
        }
        for bad in [".", "..", "-.", "a.", ".a", "a..b", "a/b", "../x", "-a", "_a", "", "a b", "a\u{0}b", "é.app", String(repeating: "a", count: 156)] {
            XCTAssertFalse(BundleIdentifier.isValid(bad), bad)
        }
    }

    func testCatalogSkipsAnInvalidBundleIDWithAWarning() throws {
        let altStore = Data(#"""
        {"name":"S","apps":[
          {"name":"Dot","bundleIdentifier":".","versions":[{"version":"1","downloadURL":"https://example.com/a.ipa"}]},
          {"name":"Ok","bundleIdentifier":"com.ok.app","versions":[{"version":"1","downloadURL":"https://example.com/b.ipa"}]}
        ]}
        """#.utf8)
        let source = try SourceParser.parse(data: altStore, from: CatalogFixtures.sourceURL)
        XCTAssertEqual(source.apps.map(\.bundleID), ["com.ok.app"])
        XCTAssertTrue(source.warnings.contains { $0.contains("bundle") }, "\(source.warnings)")

        let playCover = Data(#"""
        [{"bundleID":"..","name":"Bad","version":"1","link":"https://example.com/a.ipa"},
         {"bundleID":"com.ok.app","name":"Ok","version":"1","link":"https://example.com/b.ipa"}]
        """#.utf8)
        let pc = try SourceParser.parse(data: playCover, from: CatalogFixtures.sourceURL)
        XCTAssertEqual(pc.apps.map(\.bundleID), ["com.ok.app"])
        XCTAssertTrue(pc.warnings.contains { $0.contains("bundle") }, "\(pc.warnings)")
    }

    func testLibraryIgnoresAnInvalidEntryReadBack() async throws {
        let scratch = try EngineScratch()
        let store = LibraryStore(paths: EiderPaths(home: scratch.url("home")))
        let options = InstallOptions()
        try await store.record(InstalledApp(bundleID: ".", name: "Dot", version: "1", build: "1", path: scratch.url("Dot.app"), options: options))
        try await store.record(InstalledApp(bundleID: "com.ok.app", name: "Ok", version: "1", build: "1", path: scratch.url("Ok.app"), options: options))
        let all = try await store.all()
        XCTAssertEqual(all.map(\.bundleID), ["com.ok.app"])
        let dot = try await store.app(bundleID: ".")
        XCTAssertNil(dot)
    }

    func testUninstallOfDotNeverTouchesTheContainersFolder() async throws {
        let scratch = try EngineScratch()
        let store = LibraryStore(paths: EiderPaths(home: scratch.url("home")))
        try await store.record(InstalledApp(bundleID: ".", name: "Dot", version: "1", build: "1", path: scratch.url("Dot.app"), options: InstallOptions()))
        let containers = scratch.url("Containers")
        try FileManager.default.createDirectory(at: containers.appendingPathComponent("com.other.app"), withIntermediateDirectories: true)
        let uninstaller = Uninstaller(store: store, containersDirectory: containers)
        do {
            try await uninstaller.uninstall(bundleID: ".", removeData: true)
            XCTFail("expected a refusal")
        } catch let failure as UninstallFailure {
            XCTAssertTrue(failure.message.contains("valid bundle id"), failure.message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: containers.appendingPathComponent("com.other.app").path))
    }

    func testDataResetRefusesAnInvalidID() throws {
        let scratch = try EngineScratch()
        // The containers folder is the scratch directory: "." resolves to scratch/Data,
        // "../Containers" to scratch/Containers/Data. Neither is any app's container.
        let inContainersItself = scratch.url("Data/Documents")
        let inSibling = scratch.url("Containers/Data/Documents")
        for folder in [inContainersItself, inSibling] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let reset = DataReset(containersDirectory: scratch.directory, isRunning: { _ in false })
        XCTAssertNil(reset.clear(bundleID: "."))
        XCTAssertNil(reset.clear(bundleID: "../Containers"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inContainersItself.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inSibling.path))
    }
}
