import Foundation
import XCTest
@testable import EiderKit

/// The settle rule, driven through a stand-in process list: an app counts as
/// running only once a process has stayed up for `settle`.
final class DiagnosticsSettleTests: XCTestCase {
    private func probe(settle: TimeInterval) -> LaunchProbe {
        LaunchProbe(reportsDirectory: FileManager.default.temporaryDirectory, settle: settle)
    }

    /// A process list in which pid 7 exists from now until `lifetime` seconds later.
    private func processList(lifetime: TimeInterval) -> @Sendable () -> [Int32] {
        let end = Date().addingTimeInterval(lifetime)
        return { Date() < end ? [7] : [] }
    }

    func testTheDefaultSettleOutlastsTheMeasuredCrashWindow() {
        // 4.4 s from first sight to death in the 2026-11-25 field report.
        XCTAssertGreaterThanOrEqual(LaunchProbe.defaultSettle, 8)
    }

    func testAProcessThatDiesBeforeTheSettleIsNotRunning() async {
        let outcome = await probe(settle: 1.5).watch(timeout: 5, pids: processList(lifetime: 0.6))
        XCTAssertEqual(outcome, .exited)
    }

    func testAProcessThatStaysUpPastTheSettleIsRunning() async {
        let started = Date()
        let outcome = await probe(settle: 0.5).watch(timeout: 5, pids: processList(lifetime: 30))
        XCTAssertEqual(outcome, .settled(pid: 7))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.5)
    }

    func testALongerSettleCatchesACrashAShorterOneMisses() async {
        // The regression itself: an app that dies 1.2 s after it appears.
        let short = await probe(settle: 0.5).watch(timeout: 5, pids: processList(lifetime: 1.2))
        XCTAssertEqual(short, .settled(pid: 7))
        let long = await probe(settle: 2).watch(timeout: 5, pids: processList(lifetime: 1.2))
        XCTAssertEqual(long, .exited)
    }

    func testNothingEverAppearing() async {
        let outcome = await probe(settle: 0.5).watch(timeout: 0.6) { [] }
        XCTAssertEqual(outcome, .neverAppeared)
    }

    /// pid 7 exists from `appearsAfter` seconds from now until `lifetime` seconds after that.
    private func lateProcessList(appearsAfter: TimeInterval, lifetime: TimeInterval) -> @Sendable () -> [Int32] {
        let begin = Date().addingTimeInterval(appearsAfter)
        let end = begin.addingTimeInterval(lifetime)
        return { Date() >= begin && Date() < end ? [7] : [] }
    }

    /// The deadline bounds the wait for a process to appear, not the settle: an
    /// app first seen at 0.8 s of a 1 s timeout is still alive when the timeout
    /// passes and must end as running once it has stayed up for the settle.
    func testAProcessFirstSeenJustBeforeTheDeadlineAndStillAliveIsRunning() async {
        let started = Date()
        let outcome = await probe(settle: 1).watch(timeout: 1, pids: lateProcessList(appearsAfter: 0.8, lifetime: 60))
        XCTAssertEqual(outcome, .settled(pid: 7))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 1.7)   // 0.8 s to appear + 1 s settle
    }

    func testAProcessFirstSeenLateThatThenDiesIsExitedNotRunning() async {
        let outcome = await probe(settle: 2).watch(timeout: 1, pids: lateProcessList(appearsAfter: 0.8, lifetime: 0.7))
        XCTAssertEqual(outcome, .exited)
    }

    func testTheFailureNoteSaysExitedOnlyForAnAppThatWasSeen() {
        let probe = probe(settle: 8)
        XCTAssertEqual(probe.failureNote(appeared: true, timeout: 20), "The app started and then exited before it had stayed up for 8 seconds.")
        XCTAssertEqual(probe.failureNote(appeared: false, timeout: 20), "The app did not start within 20 seconds.")
    }
}
