import Foundation
import XCTest
@testable import EiderKit

final class LibraryStoreTests: XCTestCase {
    private func app(_ id: String, name: String = "App", version: String = "1.0") -> InstalledApp {
        InstalledApp(
            bundleID: id, name: name, version: version, build: "1",
            path: URL(fileURLWithPath: "/tmp/\(name).app"), options: InstallOptions(macIdiom: true)
        )
    }

    func testMissingAndEmptyFilesAreAnEmptyLibrary() async throws {
        let scratch = try EngineScratch()
        let paths = EiderPaths(home: scratch.url("home"))
        let store = LibraryStore(paths: paths)
        let missing = try await store.all()
        XCTAssertTrue(missing.isEmpty)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try Data().write(to: paths.libraryFile)
        let empty = try await store.all()
        XCTAssertTrue(empty.isEmpty)
    }

    func testRecordReplacesByBundleIDAndSurvivesANewStore() async throws {
        let scratch = try EngineScratch()
        let paths = EiderPaths(home: scratch.url("home"))
        let store = LibraryStore(paths: paths)
        try await store.record(app("a.one", name: "Zed"))
        try await store.record(app("a.two", name: "Alpha"))
        try await store.record(app("a.one", name: "Zed", version: "2.0"))

        let reopened = LibraryStore(paths: paths)
        let all = try await reopened.all()
        XCTAssertEqual(all.map(\.bundleID), ["a.two", "a.one"], "sorted by name, one entry per bundle id")
        let replaced = try await reopened.app(bundleID: "a.one")
        XCTAssertEqual(replaced?.version, "2.0")
        XCTAssertEqual(replaced?.options.macIdiom, true)
        let absent = try await reopened.app(bundleID: "nope")
        XCTAssertNil(absent)
    }

    func testRemove() async throws {
        let scratch = try EngineScratch()
        let store = LibraryStore(paths: EiderPaths(home: scratch.url("home")))
        try await store.record(app("a.one"))
        try await store.remove(bundleID: "a.one")
        try await store.remove(bundleID: "never.there")
        let remaining = try await store.all()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAFileThatDoesNotDecodeIsAnErrorAndIsLeftAlone() async throws {
        let scratch = try EngineScratch()
        let paths = EiderPaths(home: scratch.url("home"))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        try Data("{not the library".utf8).write(to: paths.libraryFile)
        let store = LibraryStore(paths: paths)
        do {
            try await store.record(app("a.one"))
            XCTFail("a corrupt library must not be overwritten")
        } catch {}
        XCTAssertEqual(try String(contentsOf: paths.libraryFile, encoding: .utf8), "{not the library")
    }
}

final class LibraryUninstallTests: XCTestCase {
    /// Moves real files to the user's Trash; the test removes what it put there.
    private func removeFromTrash(prefix: String) {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [] where name.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
        }
    }

    func testUninstallTrashesTheAppAndItsDataAndForgetsIt() async throws {
        let scratch = try EngineScratch()
        let unique = "EiderUninstallTest-\(UUID().uuidString.prefix(8))"
        defer { removeFromTrash(prefix: unique); removeFromTrash(prefix: "test.\(unique)") }
        let bundleID = "test.\(unique)"
        let appURL = scratch.url("\(unique).app")
        let containers = scratch.url("Containers")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: containers.appendingPathComponent(bundleID), withIntermediateDirectories: true)
        let store = LibraryStore(paths: EiderPaths(home: scratch.url("home")))
        try await store.record(InstalledApp(bundleID: bundleID, name: unique, version: "1", build: "1", path: appURL, options: InstallOptions()))

        try await Uninstaller(store: store, containersDirectory: containers).uninstall(bundleID: bundleID, removeData: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: appURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: containers.appendingPathComponent(bundleID).path))
        let remaining = try await store.app(bundleID: bundleID)
        XCTAssertNil(remaining)
    }

    func testContainerIsKeptUnlessAsked() async throws {
        let scratch = try EngineScratch()
        let unique = "EiderKeepData-\(UUID().uuidString.prefix(8))"
        defer { removeFromTrash(prefix: unique) }
        let bundleID = "test.\(unique)"
        let appURL = scratch.url("\(unique).app")
        let containers = scratch.url("Containers")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: containers.appendingPathComponent(bundleID), withIntermediateDirectories: true)
        let store = LibraryStore(paths: EiderPaths(home: scratch.url("home")))
        try await store.record(InstalledApp(bundleID: bundleID, name: unique, version: "1", build: "1", path: appURL, options: InstallOptions()))

        try await Uninstaller(store: store, containersDirectory: containers).uninstall(bundleID: bundleID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: containers.appendingPathComponent(bundleID).path))
    }

    func testUnknownBundleIDIsAnError() async throws {
        let scratch = try EngineScratch()
        let store = LibraryStore(paths: EiderPaths(home: scratch.url("home")))
        do {
            try await Uninstaller(store: store, containersDirectory: scratch.url("c")).uninstall(bundleID: "no.such.app")
            XCTFail("expected a failure")
        } catch let failure as UninstallFailure {
            XCTAssertTrue(failure.message.contains("no.such.app"))
        }
    }
}
