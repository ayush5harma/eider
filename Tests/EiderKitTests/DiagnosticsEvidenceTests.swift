import Foundation
import XCTest
@testable import EiderKit

final class DiagnosticsEvidenceTests: XCTestCase {
    func testLogArgumentsScopeToTheProcessAndEscapeItsName() {
        let arguments = LaunchEvidence.logArguments(process: "A\"B\\C", since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(arguments.first, "show")
        let predicate = arguments.last ?? ""
        XCTAssertEqual(predicate, "process == \"A\\\"B\\\\C\" OR eventMessage CONTAINS \"A\\\"B\\\\C\"")
        XCTAssertTrue(arguments.contains("--start"))
    }

    func testTimestampIsLocalTimeToTheSecond() {
        let text = LaunchEvidence.logTimestamp(Date())
        XCTAssertNotNil(text.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression), text)
    }

    func testNewestReportForTheProcessSinceTheLaunchWins() throws {
        let scratch = try EngineScratch()
        let directory = scratch.url("reports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        func report(_ name: String, age: TimeInterval) throws {
            let file = directory.appendingPathComponent(name)
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
        }
        try report("Probe-2026-11-11-100000.ips", age: 5)
        try report("Probe-2026-11-11-100005.ips", age: 2)
        try report("Probe-2026-11-10-090000.ips", age: 86_400)   // an old crash: before the launch
        try report("ProbeOther-2026-11-11-100006.ips", age: 1)   // another process with a longer name
        try report("Probe-2026-11-11-100007.txt", age: 0)        // not a crash report

        let found = LaunchEvidence.newestCrashReport(process: "Probe", in: directory, since: now.addingTimeInterval(-10))
        XCTAssertEqual(found?.lastPathComponent, "Probe-2026-11-11-100005.ips")
        XCTAssertNil(LaunchEvidence.newestCrashReport(process: "Probe", in: directory, since: now.addingTimeInterval(10)))
        XCTAssertNil(LaunchEvidence.newestCrashReport(process: "Probe", in: scratch.url("missing"), since: now))
    }

    // MARK: Log text

    /// A multi-line event (an exception's backtrace) is printed by `log show` as
    /// the first line followed by tab-indented continuation lines. They must
    /// survive: the classifier reads the "thrown from" frame out of them.
    func testLogOutputKeepsTabIndentedContinuationLines() {
        let output = """
        Timestamp                       Ty Process[PID:TID]
        2026-11-25 23:49:20.471 Df Telegram[32403:314a77] (CoreFoundation) *** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'x'
        \t0   CoreFoundation                      0x00000001996d680c __exceptionPreprocess + 176
        \t5   nicegram-BlackScreenFIX.dylib       0x0000000101118d64 +[FCAlertView getResourcesBundle] + 176

        2026-11-25 23:49:20.980 Df Telegram[32403:314a77] next event
        """
        let lines = LaunchEvidence.lines(ofLogOutput: output)
        XCTAssertEqual(lines.count, 5)   // the blank line is dropped
        XCTAssertTrue(lines.contains { $0.contains("nicegram-BlackScreenFIX.dylib") }, "\(lines)")
        let diagnosis = LaunchClassifier.classify(lines: lines, processName: "Telegram", appBinaries: ["nicegram-BlackScreenFIX.dylib"])
        XCTAssertEqual(diagnosis.code, .uncaughtException)
        XCTAssertTrue(diagnosis.summary.contains("in +[FCAlertView getResourcesBundle]"), diagnosis.summary)
    }

    // MARK: The app's own binaries

    func testAppBinaryNamesAreTheMachOFilesInsideTheBundle() throws {
        let scratch = try EngineScratch()
        let app = scratch.url("Probe.app")
        let framework = app.appendingPathComponent("Frameworks/Kit.framework", isDirectory: true)
        try FileManager.default.createDirectory(at: framework, withIntermediateDirectories: true)
        let machO = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(repeating: 0, count: 28)   // MH_MAGIC_64, little endian
        try machO.write(to: app.appendingPathComponent("Probe"))
        try machO.write(to: app.appendingPathComponent("Frameworks/tweak.dylib"))
        try machO.write(to: framework.appendingPathComponent("Kit"))
        try Data("not a binary".utf8).write(to: app.appendingPathComponent("Info.plist"))
        try Data(repeating: 0, count: 64).write(to: app.appendingPathComponent("data.bin"))

        XCTAssertEqual(LaunchEvidence.appBinaryNames(inBundle: app), ["Probe", "tweak.dylib", "Kit"])
        XCTAssertEqual(LaunchEvidence.appBinaryNames(inBundle: scratch.url("missing")), [])
    }

    /// An app bug thrown through the camera shim's AVFoundation wrapper must not
    /// read "thrown from libipacamera.dylib": the shim is Eider's, not the app's.
    func testEidersShimsAreNotTheAppsBinariesAndTheNextAppFrameIsNamed() throws {
        let scratch = try EngineScratch()
        let app = scratch.url("Probe.app")
        let frameworks = app.appendingPathComponent("Frameworks", isDirectory: true)
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let machO = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(repeating: 0, count: 28)
        try machO.write(to: app.appendingPathComponent("Probe"))
        for shim in Shim.allCases { try machO.write(to: frameworks.appendingPathComponent(shim.rawValue)) }

        let binaries = LaunchEvidence.appBinaryNames(inBundle: app)
        XCTAssertEqual(binaries, ["Probe"])

        let lines = [
            "*** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: 'format not supported'",
            "0   CoreFoundation                      0x00000001996d680c __exceptionPreprocess + 176",
            "1   libipacamera.dylib                  0x0000000102a00000 ipa_setActiveVideoMinFrameDuration + 80",
            "2   Probe                               0x0000000100001234 -[CameraController start] + 120",
        ]
        let diagnosis = LaunchClassifier.classify(lines: lines, processName: "Probe", appBinaries: binaries)
        XCTAssertEqual(
            diagnosis.summary,
            "The app stopped on an uncaught NSInvalidArgumentException (format not supported), thrown from Probe in -[CameraController start].")
        XCTAssertFalse(diagnosis.summary.contains("libipacamera"))
    }

    func testReportTextIsCapped() throws {
        let scratch = try EngineScratch()
        let file = scratch.url("big.ips")
        try Data(repeating: 0x61, count: 4096).write(to: file)
        XCTAssertEqual(LaunchEvidence.lines(ofReport: file, maxBytes: 100).joined().count, 100)
    }
}
