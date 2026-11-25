import Foundation
import XCTest
@testable import EiderKit

/// Sample lines are the shapes `log show` and crash reports produce on macOS.
final class DiagnosticsClassifierTests: XCTestCase {
    private func classify(_ lines: [String], process: String? = "Probe", binaries: Set<String> = []) -> LaunchDiagnosis {
        LaunchClassifier.classify(lines: lines, processName: process, appBinaries: binaries)
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

    // MARK: Uncaught exceptions

    /// `log show --style compact` for the process that crashed in the 2026-11-25
    /// field report: a tweak dylib injected into the IPA, a missing resource bundle.
    /// Unfiltered: NSException puts "*** First throw call stack:" and "(" between
    /// the Terminating line and the first frame (re-read from the log 2026-11-26
    /// after a fixture without them let a frame search that gave up on them pass).
    private static let exceptionLog = [
        "2026-11-25 23:49:16.617 Df Telegram[32403:314a77] (CoreFoundation) something unrelated",
        "2026-11-25 23:49:20.471 Df Telegram[32403:314a77] (CoreFoundation) *** Terminating app due to uncaught exception 'NSInvalidArgumentException', reason: '*** -[NSBundle initWithURL:]: nil URL argument'",
        "*** First throw call stack:",
        "(",
        "\t0   CoreFoundation                      0x00000001996d680c __exceptionPreprocess + 176",
        "\t1   libobjc.A.dylib                     0x00000001952d85ec objc_exception_throw + 88",
        "\t2   Foundation                          0x0000000195bb9328 -[NSBundle _initUniqueWithURL:] + 0",
        "\t3   Foundation                          0x0000000195b00bf8 -[NSBundle initWithURL:] + 36",
        "\t4   Foundation                          0x0000000195b00ba4 +[NSBundle bundleWithURL:] + 32",
        "\t5   nicegram-BlackScreenFIX.dylib       0x0000000101118d64 +[FCAlertView getResourcesBundle] + 176",
    ]

    func testUncaughtExceptionNamesTheExceptionTheReasonAndTheAppBinaryThatThrew() {
        let diagnosis = classify(Self.exceptionLog, process: "Telegram", binaries: ["Telegram", "nicegram-BlackScreenFIX.dylib"])
        XCTAssertEqual(diagnosis.code, .uncaughtException)
        XCTAssertEqual(
            diagnosis.summary,
            "The app stopped on an uncaught NSInvalidArgumentException (*** -[NSBundle initWithURL:]: nil URL argument), thrown from nicegram-BlackScreenFIX.dylib in +[FCAlertView getResourcesBundle].")
        XCTAssertEqual(diagnosis.evidence.count, 2)
        XCTAssertTrue(diagnosis.evidence[0].contains("Terminating app due to uncaught exception"))
        XCTAssertTrue(diagnosis.evidence[1].contains("nicegram-BlackScreenFIX.dylib"))
    }

    func testUncaughtExceptionOmitsThrownFromWhenNoFrameIsInTheApp() {
        // Same lines, but the app's binaries are not among the frames' images.
        let diagnosis = classify(Self.exceptionLog, process: "Telegram", binaries: ["Telegram"])
        XCTAssertEqual(diagnosis.code, .uncaughtException)
        XCTAssertEqual(
            diagnosis.summary,
            "The app stopped on an uncaught NSInvalidArgumentException (*** -[NSBundle initWithURL:]: nil URL argument).")
        XCTAssertEqual(diagnosis.evidence.count, 1)

        let unknownBinaries = classify(Self.exceptionLog, process: "Telegram")
        XCTAssertFalse(unknownBinaries.summary.contains("thrown from"))
    }

    func testUncaughtExceptionTakesTheFirstAppFrameNotALaterOne() {
        let lines = Self.exceptionLog + ["\t6   Telegram                            0x0000000100001234 main + 40"]
        let diagnosis = classify(lines, process: "Telegram", binaries: ["Telegram", "nicegram-BlackScreenFIX.dylib"])
        XCTAssertTrue(diagnosis.summary.contains("thrown from nicegram-BlackScreenFIX.dylib"), diagnosis.summary)
    }

    func testAnAppBinaryWithASpaceInItsNameIsMatched() {
        let lines = [
            "*** Terminating app due to uncaught exception 'NSGenericException', reason: 'boom'",
            "1   Probe Helper                       0x0000000100001234 -[Thing run] + 12",
        ]
        let diagnosis = classify(lines, binaries: ["Probe Helper"])
        XCTAssertEqual(diagnosis.summary, "The app stopped on an uncaught NSGenericException (boom), thrown from Probe Helper in -[Thing run].")
    }

    func testUncaughtExceptionOutranksTheDenialsLoggedBeforeIt() {
        let diagnosis = classify(
            ["kernel: Sandbox: Probe(4242) deny(1) file-read-data /x", "Probe SecItemAdd failed: -34018"] + Self.exceptionLog,
            process: "Probe")
        XCTAssertEqual(diagnosis.code, .uncaughtException)
    }

    func testUncaughtExceptionIsFoundInACrashReportLine() {
        let ips = "{\"asi\":{\"CoreFoundation\":[\"*** Terminating app due to uncaught exception 'NSRangeException', reason: '*** index 3 beyond bounds [0 .. 1]'\"]}}"
        let diagnosis = classify([ips])
        XCTAssertEqual(diagnosis.code, .uncaughtException)
        XCTAssertTrue(diagnosis.summary.contains("NSRangeException (*** index 3 beyond bounds [0 .. 1])"), diagnosis.summary)
    }

    func testAnExceptionLineWithoutAReasonStillClassifies() {
        let diagnosis = classify(["*** Terminating app due to uncaught exception 'MyError'"])
        XCTAssertEqual(diagnosis.code, .uncaughtException)
        XCTAssertEqual(diagnosis.summary, "The app stopped on an uncaught MyError.")
    }

    func testBacktraceWithoutAnExceptionLineIsNotAnUncaughtException() {
        let diagnosis = classify(Array(Self.exceptionLog.dropFirst(2)), process: "Telegram", binaries: ["nicegram-BlackScreenFIX.dylib"])
        XCTAssertEqual(diagnosis.code, .unknown)
    }

    // MARK: Uncaught exceptions: the denial that may be behind them

    func testAnExceptionKeepsFirstPlaceButNamesASandboxDenialLoggedForTheSameProcess() {
        let denial = "2026-11-25 23:49:19.900 Df kernel[0:1] (Sandbox) Sandbox: Telegram(32403) deny(1) mach-lookup com.apple.foo"
        let diagnosis = classify([denial] + Self.exceptionLog, process: "Telegram", binaries: ["nicegram-BlackScreenFIX.dylib"])
        XCTAssertEqual(diagnosis.code, .uncaughtException)
        XCTAssertTrue(diagnosis.summary.hasPrefix("The app stopped on an uncaught NSInvalidArgumentException"), diagnosis.summary)
        XCTAssertTrue(diagnosis.summary.contains("sandbox refused something"), diagnosis.summary)
        XCTAssertEqual(diagnosis.evidence.count, 3)
        XCTAssertTrue(diagnosis.evidence[0].contains("Terminating app"))
        XCTAssertTrue(diagnosis.evidence[1].contains("nicegram-BlackScreenFIX.dylib"))
        XCTAssertEqual(diagnosis.evidence[2], denial)
    }

    func testAnExceptionNamesSystemPolicyAndKeychainDenialsToo() {
        let policy = classify(
            ["kernel: (Sandbox) System Policy: Telegram(32403) deny(1) file-write-create /Users/a/Library/Group Containers/g"] + Self.exceptionLog,
            process: "Telegram")
        XCTAssertEqual(policy.code, .uncaughtException)
        XCTAssertTrue(policy.summary.contains("System Policy"), policy.summary)

        let keychain = classify(["Telegram SecItemAdd failed: -34018"] + Self.exceptionLog, process: "Telegram")
        XCTAssertEqual(keychain.code, .uncaughtException)
        XCTAssertTrue(keychain.summary.contains("--no-keychain"), keychain.summary)
    }

    func testAnotherProcessesDenialIsNotAddedToAnException() {
        let diagnosis = classify(["kernel: (Sandbox) Sandbox: Safari(11) deny(1) mach-lookup x"] + Self.exceptionLog, process: "Telegram")
        XCTAssertFalse(diagnosis.summary.contains("sandbox"), diagnosis.summary)
        XCTAssertEqual(diagnosis.evidence.count, 1)
    }

    // MARK: Uncaught exceptions: what is read out of the lines

    func testExceptionNameAndReasonAreStrippedOfControlCharactersAndCapped() {
        let reason = "bad\u{1B}[31m thing" + String(repeating: "x", count: 1000)
        let diagnosis = classify(["*** Terminating app due to uncaught exception 'NS\u{7}Err', reason: '\(reason)'"])
        XCTAssertEqual(diagnosis.code, .uncaughtException)
        XCTAssertFalse(diagnosis.summary.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }, diagnosis.summary)
        XCTAssertTrue(diagnosis.summary.contains("NSErr"))
        XCTAssertLessThan(diagnosis.summary.count, LaunchClassifier.maxEvidenceWidth + 100)
    }

    func testTheFrameSearchStopsAtTheFirstLineThatIsNotABacktraceFrame() {
        let lines = [
            "*** Terminating app due to uncaught exception 'NSGenericException', reason: 'boom'",
            "1   Foundation                         0x0000000195b00bf8 -[NSBundle initWithURL:] + 36",
            "2026-11-25 23:49:21.000 Df Telegram[32403:1] an unrelated event",
            "5   nicegram-BlackScreenFIX.dylib       0x0000000101118d64 +[FCAlertView getResourcesBundle] + 176",
        ]
        let diagnosis = classify(lines, process: "Telegram", binaries: ["nicegram-BlackScreenFIX.dylib"])
        XCTAssertEqual(diagnosis.summary, "The app stopped on an uncaught NSGenericException (boom).")
    }

    func testOnlyAShortPreambleMaySitBeforeTheFirstFrame() {
        let frame = "5   nicegram-BlackScreenFIX.dylib       0x0000000101118d64 +[FCAlertView getResourcesBundle] + 176"
        let terminating = "*** Terminating app due to uncaught exception 'NSGenericException', reason: 'boom'"
        let preamble = ["*** First throw call stack:", "("]
        let found = classify([terminating] + preamble + [frame], process: "Telegram", binaries: ["nicegram-BlackScreenFIX.dylib"])
        XCTAssertTrue(found.summary.contains("thrown from nicegram-BlackScreenFIX.dylib"))

        let unrelated = (1...4).map { "2026-11-25 23:49:21.00\($0) Df Telegram[32403:1] an unrelated event" }
        let tooFar = classify([terminating] + unrelated + [frame], process: "Telegram", binaries: ["nicegram-BlackScreenFIX.dylib"])
        XCTAssertEqual(tooFar.summary, "The app stopped on an uncaught NSGenericException (boom).")
    }

    func testACrashReportsBacktraceHeaderDoesNotEndTheFrameSearch() {
        let lines = [
            "*** Terminating app due to uncaught exception 'NSGenericException', reason: 'boom'",
            "Last Exception Backtrace:",
            "0   CoreFoundation                      0x00000001996d680c __exceptionPreprocess + 176",
            "1   nicegram-BlackScreenFIX.dylib       0x0000000101118d64 +[FCAlertView getResourcesBundle] + 176",
        ]
        let diagnosis = classify(lines, binaries: ["nicegram-BlackScreenFIX.dylib"])
        XCTAssertTrue(diagnosis.summary.contains("thrown from nicegram-BlackScreenFIX.dylib"), diagnosis.summary)
    }

    func testTheMarkerIsSharedWithTheProbe() {
        XCTAssertEqual(LaunchClassifier.exceptionMarker, "Terminating app due to uncaught exception")
    }
}
