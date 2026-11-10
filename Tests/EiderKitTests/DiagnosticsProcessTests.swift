import Darwin
import Foundation
import XCTest
@testable import EiderKit

final class DiagnosticsProcessTests: XCTestCase {
    /// The test runner is itself a process running from a folder, so it can stand in for an app.
    func testFindsAProcessByItsBundleFolderEvenThroughASymlinkedTempPath() throws {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        XCTAssertGreaterThan(proc_pidpath(getpid(), &buffer, UInt32(buffer.count)), 0)
        let executable = URL(fileURLWithPath: String(cString: buffer))
        let scratch = try EngineScratch()
        let link = scratch.url("link")   // under $TMPDIR: /var/folders, itself a symlink to /private/var
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable.deletingLastPathComponent())

        XCTAssertTrue(RunningProcesses.pids(insideBundle: link).contains(ProcessInfo.processInfo.processIdentifier))
        XCTAssertTrue(RunningProcesses.pids(insideBundle: scratch.url("nowhere")).isEmpty)
    }

    func testPhysicalPathKeepsPrivatePrefix() throws {
        let scratch = try EngineScratch()
        XCTAssertTrue(RunningProcesses.physicalPath(scratch.directory.path).hasPrefix("/private/var"), scratch.directory.path)
    }
}
