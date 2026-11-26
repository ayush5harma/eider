import Foundation
import XCTest
@testable import EiderKit

/// An app that stays running with an empty window: its launch sequence built
/// the first screen before Catalyst's late first scene and never attached it.
final class DiagnosticsWindowTests: XCTestCase {
    /// As YouTube 21.47.6 logged it on 2026-11-26 (unified log, compact style).
    private let youTubeLine = "2026-11-26 23:09:03.842 E  YouTube[47585:622f0] [com.apple.UIKit:Presentation] Attempt to present <YTFirstTimeSignInViewController: 0x75595df200> on <YTAppViewControllerImpl: 0x755b594000> (from <YTHeaderContentComboViewController: 0x7559526300>) whose view is not in the window hierarchy."

    func testTheCodeIsStable() {
        XCTAssertEqual(LaunchDiagnosis.Code.windowNotAttached.rawValue, "window_not_attached")
    }

    func testMarkerAndAWindowWithNoContentIsDiagnosed() throws {
        let diagnosis = try XCTUnwrap(LaunchClassifier.emptyWindow(lines: [youTubeLine], processName: "YouTube", contentElements: 0))
        XCTAssertEqual(diagnosis.code, .windowNotAttached)
        XCTAssertTrue(diagnosis.summary.contains("still running"), diagnosis.summary)
        XCTAssertTrue(diagnosis.summary.contains("report"), diagnosis.summary)
        XCTAssertEqual(diagnosis.evidence.first, youTubeLine)
        XCTAssertTrue(diagnosis.evidence.contains { $0.contains("no content") }, "\(diagnosis.evidence)")
    }

    /// One text field is content (the e2e probe's whole window); an app with
    /// content that logs the same benign warning is not called empty.
    func testAWindowWithContentIsNotDiagnosedEvenWithTheMarker() {
        for count in [1, 7, 79] {
            XCTAssertNil(LaunchClassifier.emptyWindow(lines: [youTubeLine], processName: "YouTube", contentElements: count), "\(count)")
        }
    }

    /// A game drawing into one Metal view exposes no content either, and is
    /// told apart only by not logging the marker.
    func testNoContentWithoutTheMarkerIsNotDiagnosed() {
        let lines = ["2026-11-27 10:00:00.000 Df PPSSPP[1:2] [com.apple.UIKit:Scene] scene connected"]
        XCTAssertNil(LaunchClassifier.emptyWindow(lines: lines, processName: "PPSSPP", contentElements: 0))
    }

    /// Without Accessibility permission the content cannot be read, and a log
    /// line alone is too common to call a window empty.
    func testUnreadableContentIsNotDiagnosed() {
        XCTAssertNil(LaunchClassifier.emptyWindow(lines: [youTubeLine], processName: "YouTube", contentElements: nil))
    }

    func testAnotherProcessesMarkerDoesNotCount() {
        XCTAssertNil(LaunchClassifier.emptyWindow(lines: [youTubeLine], processName: "Delta", contentElements: 0))
    }
}
