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

    func testReportTextIsCapped() throws {
        let scratch = try EngineScratch()
        let file = scratch.url("big.ips")
        try Data(repeating: 0x61, count: 4096).write(to: file)
        XCTAssertEqual(LaunchEvidence.lines(ofReport: file, maxBytes: 100).joined().count, 100)
    }
}
