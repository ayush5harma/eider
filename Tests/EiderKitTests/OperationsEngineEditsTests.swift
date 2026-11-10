import Foundation
import XCTest
@testable import EiderKit

/// The three small edits made to modules owned elsewhere: reset-on-install,
/// the source fetch's idle timeout, and the shim lookup through a symlink.
final class OperationsEngineEditsTests: XCTestCase {
    // MARK: resetData

    private func makeContainer(_ scratch: EngineScratch, bundleID: String) throws -> URL {
        let data = scratch.url("containers/\(bundleID)/Data")
        for folder in ["Documents", "Library/Preferences", "Library/Caches"] {
            try FileManager.default.createDirectory(at: data.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: data.appendingPathComponent("Documents/state.txt"))
        return data
    }

    func testResetEmptiesContainerFoldersAndKeepsTheRoot() throws {
        let scratch = try EngineScratch()
        let data = try makeContainer(scratch, bundleID: "test.reset")
        let reset = DataReset(containersDirectory: scratch.url("containers"), isRunning: { _ in false })

        let note = reset.clear(bundleID: "test.reset")

        XCTAssertNotNil(note)
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path), "the container root belongs to the system")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: data.path), [])
    }

    func testResetWithoutAContainerIsANoOp() throws {
        let scratch = try EngineScratch()
        let reset = DataReset(containersDirectory: scratch.url("containers"), isRunning: { _ in false })
        XCTAssertNil(reset.clear(bundleID: "test.none"))
    }

    func testResetRefusesWhileTheAppRuns() {
        let reset = DataReset(containersDirectory: URL(fileURLWithPath: "/nonexistent"), isRunning: { $0 == "Run" })
        XCTAssertThrowsError(try reset.refuseIfRunning(name: "Run")) {
            XCTAssertEqual(($0 as? InstallFailure)?.code, .appRunning)
        }
        XCTAssertNoThrow(try reset.refuseIfRunning(name: "Other"))
    }

    /// The refusal must come before the previous copy is moved aside, so the
    /// installer is run against a destination that already holds the app.
    func testInstallWithResetRefusesAHostedRunningAppAndTouchesNothing() async throws {
        let scratch = try EngineScratch()
        let stage = scratch.url("stage/Payload/Run.app")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try Data("not a binary".utf8).write(to: stage.appendingPathComponent("Run"))
        let info = ["CFBundleIdentifier": "test.run", "CFBundleExecutable": "Run", "CFBundleName": "Run"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: stage.appendingPathComponent("Info.plist"))
        let ipa = scratch.url("run.ipa")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-qry", ipa.path, "Payload"]
        zip.currentDirectoryURL = scratch.url("stage")
        try zip.run()
        zip.waitUntilExit()

        let destination = scratch.url("apps")
        let existing = destination.appendingPathComponent("Run.app")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let data = try makeContainer(scratch, bundleID: "test.run")
        let shims = ShimLocator(environment: [ShimLocator.overrideVariable: try scratch.placeholderShims().path], executableURL: nil, resourceURL: nil)
        let installer = Installer(
            paths: EiderPaths(home: scratch.url("home")), shims: shims, store: nil,
            maxUncompressedBytes: Installer.defaultMaxUncompressedBytes,
            reset: DataReset(containersDirectory: scratch.url("containers"), isRunning: { _ in true })
        )

        do {
            _ = try await installer.install(ipa: ipa, options: InstallOptions(destination: destination, resetData: true))
            XCTFail("a running app must not be reset")
        } catch let failure as InstallFailure {
            XCTAssertEqual(failure.code, .appRunning)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.appendingPathComponent("Documents/state.txt").path))
    }

    // MARK: Source fetch timeouts

    func testSourceFetchUsesAnIdleTimeoutNotAWholeTransferOne() {
        let configuration = URLSessionConfiguration.ephemeral
        SourceFetcher.configure(configuration)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, SourceFetcher.idleTimeout)
        XCTAssertGreaterThan(configuration.timeoutIntervalForResource, SourceFetcher.idleTimeout * 10)
    }

    // MARK: Shim lookup through a symlink

    func testShimsAreFoundBesideTheRealExecutableWhenTheCLIIsSymlinked() throws {
        let scratch = try EngineScratch()
        let cellar = scratch.url("Cellar/eider/1.0")
        let shims = cellar.appendingPathComponent("share/eider/shims")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cellar.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: shims.appendingPathComponent(Shim.groups.rawValue))
        try Data().write(to: cellar.appendingPathComponent("bin/eider"))
        // Homebrew links the keg's binary into prefix/bin, which has no share/eider of its own.
        let linkDirectory = scratch.url("prefix/bin")
        try FileManager.default.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        let link = linkDirectory.appendingPathComponent("eider")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: cellar.appendingPathComponent("bin/eider"))

        let locator = ShimLocator(environment: [:], executableURL: link, resourceURL: nil)

        XCTAssertEqual(
            try locator.url(for: .groups).resolvingSymlinksInPath().path,
            shims.appendingPathComponent(Shim.groups.rawValue).resolvingSymlinksInPath().path
        )
    }
}
