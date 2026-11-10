import Foundation
import XCTest
@testable import EiderKit

/// Sample lines are the shapes `log show` and crash reports produce on macOS.
final class DiagnosticsClassifierTests: XCTestCase {
    private func classify(_ lines: [String], process: String? = "Probe") -> LaunchDiagnosis {
        LaunchClassifier.classify(lines: lines, processName: process)
    }

    func testSystemPolicyDenialIsToldApartFromASandboxDenial() {
        let policy = classify(["2026-11-11 10:00:00.1 Df kernel[0:1] (Sandbox) System Policy: Probe(4242) deny(1) file-write-create /Users/a/Library/Group Containers/g"])
        XCTAssertEqual(policy.code, .systemPolicy)
        XCTAssertEqual(policy.evidence.count, 1)

        let sandbox = classify(["2026-11-11 10:00:00.1 Df kernel[0:1] (Sandbox) Sandbox: Probe(4242) deny(1) mach-lookup com.apple.foo"])
        XCTAssertEqual(sandbox.code, .sandboxDenial)

        let byReporter = classify(["2026-11-11 10:00:00.1 Df sandboxd[1:2] [com.apple.sandbox.reporting:violation] Probe(4242) deny(1) network-outbound"])
        XCTAssertEqual(byReporter.code, .sandboxDenial)
    }

    func testAnotherProcessesDenialIsIgnored() {
        let diagnosis = classify(["kernel: System Policy: Safari(11) deny(1) file-read-data /x"])
        XCTAssertEqual(diagnosis.code, .unknown)
    }

    func testKeychainMissingEntitlement() {
        let diagnosis = classify(["Probe[4242:1] SecItemAdd failed: -34018 A required entitlement isn't present."])
        XCTAssertEqual(diagnosis.code, .keychainEntitlement)
        XCTAssertTrue(diagnosis.summary.contains("--no-keychain"))
    }

    func testDyldLibraryNotLoadedNamesTheLibrary() {
        let diagnosis = classify(["dyld[4242]: Library not loaded: @rpath/ProbeKit.framework/ProbeKit", "  Referenced from: /Apps/IPA Probe.app/Contents/MacOS/Probe"])
        XCTAssertEqual(diagnosis.code, .libraryNotLoaded)
        XCTAssertTrue(diagnosis.summary.contains("@rpath/ProbeKit.framework/ProbeKit"), diagnosis.summary)
    }

    func testDyldSymbolNotFoundNamesTheSymbol() {
        let diagnosis = classify(["dyld[4242]: Symbol not found: _OBJC_CLASS_$_UIFoo (which was expected in UIKit)"])
        XCTAssertEqual(diagnosis.code, .symbolNotFound)
        XCTAssertTrue(diagnosis.summary.contains("_OBJC_CLASS_$_UIFoo"), diagnosis.summary)
    }

    func testInvalidSignatureFromCrashReportAndFromLog() {
        XCTAssertEqual(classify(["Termination Reason:    Namespace CODESIGNING, Code 2 Invalid Page"]).code, .invalidSignature)
        XCTAssertEqual(classify(["kernel: AMFI: code signature validation failed."]).code, .invalidSignature)
        XCTAssertEqual(classify(["Probe: code signature invalid"]).code, .invalidSignature)
    }

    func testEncryptedBinary() {
        XCTAssertEqual(classify(["dyld: terminating because inserted dylib ... mach-o file is encrypted (FairPlay)"]).code, .encryptedBinary)
    }

    func testCrashCauseOutranksDenialsLoggedAlongsideIt() {
        let diagnosis = classify([
            "kernel: Sandbox: Probe(4242) deny(1) file-read-data /private/var/db/x",
            "dyld[4242]: Library not loaded: @rpath/Gone.framework/Gone",
        ])
        XCTAssertEqual(diagnosis.code, .libraryNotLoaded)
    }

    func testUnknownKeepsTheLastRelevantLines() {
        let lines = (1...20).map { "Probe line \($0)" } + ["unrelated"]
        let diagnosis = classify(lines)
        XCTAssertEqual(diagnosis.code, .unknown)
        XCTAssertEqual(diagnosis.evidence.count, LaunchClassifier.maxEvidenceLines)
        XCTAssertEqual(diagnosis.evidence.last, "Probe line 20")
        XCTAssertFalse(diagnosis.summary.isEmpty)
    }

    func testEmptyInputIsUnknownWithNoEvidence() {
        let diagnosis = classify([])
        XCTAssertEqual(diagnosis.code, .unknown)
        XCTAssertTrue(diagnosis.evidence.isEmpty)
    }

    func testIPSJSONLineBreaksAreSplitAndLongLinesCut() {
        let blob = String(repeating: "x", count: 1000)
        let ips = "{\"pid\":4242,\"dyldErrorMessage\":\"dyld[4242]: Library not loaded: @rpath/A.framework/A\\n  Referenced from: \(blob)\"}"
        let diagnosis = classify([ips])
        XCTAssertEqual(diagnosis.code, .libraryNotLoaded)
        XCTAssertTrue(diagnosis.evidence.allSatisfy { $0.count <= LaunchClassifier.maxEvidenceWidth + 3 })
    }

    func testDiagnosisRoundTripsThroughJSON() throws {
        let diagnosis = LaunchDiagnosis(code: .systemPolicy, summary: "s", evidence: ["e"])
        let data = try JSONEncoder().encode(diagnosis)
        XCTAssertEqual(try JSONDecoder().decode(LaunchDiagnosis.self, from: data), diagnosis)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"system_policy\""))
    }
}
