import Foundation
import XCTest
@testable import EiderKit

/// Finding 9: nothing destructive happens before the new copy is ready, the old
/// copy is never deleted outright, and data is reset only once the new app is in place.
final class SecurityPlacementTests: XCTestCase {
    private struct Setup {
        let scratch: EngineScratch
        let destination: URL
        let existing: URL
        let fresh: URL
        let data: URL
        let log: PlacementLog
    }

    /// An installed Thing.app holding "old", a finished one holding "new" in the work
    /// folder, and a container with state in it.
    private func makeSetup(existingContent: Bool = true) throws -> Setup {
        let scratch = try EngineScratch()
        let destination = scratch.url("apps")
        let existing = destination.appendingPathComponent("Thing.app")
        let fresh = scratch.url("work/Thing.app")
        for (folder, text) in [(existing, "old"), (fresh, "new")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("marker"))
        }
        let data = scratch.url("containers/com.thing.app/Data")
        try FileManager.default.createDirectory(at: data.appendingPathComponent("Documents"), withIntermediateDirectories: true)
        return Setup(scratch: scratch, destination: destination, existing: existing, fresh: fresh, data: data, log: PlacementLog())
    }

    private func placer(_ setup: Setup, resetData: Bool = true, trashFails: Bool = false, finalMoveFails: Bool = false) -> AppPlacer {
        let log = setup.log
        let bin = setup.scratch.url("trash")
        let trash = TrashLog(bin: bin)
        let target = setup.existing
        let owned = InstalledApp(bundleID: "com.thing.app", name: "Thing", version: "1", build: "1", path: target, options: InstallOptions())
        return AppPlacer(
            force: false, resetData: resetData,
            reset: DataReset(containersDirectory: setup.scratch.url("containers"), isRunning: { _ in false }),
            recorded: [owned],
            trash: { url in
                log.add("trash")
                if trashFails { throw CocoaError(.fileWriteNoPermission) }
                return trash.add(url)
            },
            move: { from, to in
                // The new copy is staged on the destination volume before anything is trashed.
                log.add(to.path == target.path ? "final" : "stage")
                if to.path == target.path, finalMoveFails, from.lastPathComponent == "Thing.app", from.path.contains(".eider-staging-") { throw CocoaError(.fileWriteVolumeReadOnly) }
                try FileManager.default.moveItem(at: from, to: to)
            },
            emit: { _, _ in })
    }

    private func read(_ bundle: URL) -> String? { try? String(contentsOf: bundle.appendingPathComponent("marker")) }

    func testTheNewCopyIsStagedBeforeTheOldOneIsTrashedAndThenMovedIn() throws {
        let setup = try makeSetup()
        let target = try placer(setup).place(setup.fresh, name: "Thing", bundleID: "com.thing.app", into: setup.destination)
        XCTAssertEqual(setup.log.entries, ["stage", "trash", "final"])
        XCTAssertEqual(read(target), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: setup.destination.path), ["Thing.app"], "no staging folder is left behind")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: setup.data.path), [], "data is reset once the new app is in place")
    }

    func testWithNoTrashTheOldCopyIsKeptNothingIsInstalledAndDataIsUntouched() throws {
        let setup = try makeSetup()
        XCTAssertThrowsError(try placer(setup, trashFails: true).place(setup.fresh, name: "Thing", bundleID: "com.thing.app", into: setup.destination)) {
            XCTAssertEqual(($0 as? InstallFailure)?.code, .trashUnavailable, "\($0)")
        }
        XCTAssertEqual(read(setup.existing), "old", "never deleted outright")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: setup.destination.path), ["Thing.app"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.data.appendingPathComponent("Documents").path))
    }

    func testWhenTheFinalMoveFailsTheOldCopyIsPutBackAndDataIsUntouched() throws {
        let setup = try makeSetup()
        XCTAssertThrowsError(try placer(setup, finalMoveFails: true).place(setup.fresh, name: "Thing", bundleID: "com.thing.app", into: setup.destination)) {
            let failure = $0 as? InstallFailure
            XCTAssertEqual(failure?.code, .placementFailed, "\($0)")
            XCTAssertTrue(failure?.message.contains("put back") == true, "\($0)")
        }
        XCTAssertEqual(read(setup.existing), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: setup.destination.path), ["Thing.app"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: setup.data.appendingPathComponent("Documents").path), "reset waits for the new app")
    }

    func testAFreshInstallNeedsNoTrash() throws {
        let setup = try makeSetup()
        try FileManager.default.removeItem(at: setup.existing)
        let target = try placer(setup, trashFails: true).place(setup.fresh, name: "Thing", bundleID: "com.thing.app", into: setup.destination)
        XCTAssertEqual(read(target), "new")
        XCTAssertEqual(setup.log.entries, ["stage", "final"])
    }
}

final class PlacementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [String] = []
    var entries: [String] { lock.withLock { _entries } }
    func add(_ entry: String) { lock.withLock { _entries.append(entry) } }
}
