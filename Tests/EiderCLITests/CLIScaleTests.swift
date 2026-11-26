import ArgumentParser
import EiderKit
import Foundation
import XCTest
@testable import eider

final class CLIScaleTests: XCTestCase {
    func testInstallDefaultsToAutoAndTakesAnyNamedSize() throws {
        XCTAssertEqual(try InstallCommand.parse(["a.ipa"]).makeOptions().interfaceScale, .auto)
        XCTAssertEqual(try InstallCommand.parse(["a.ipa", "--interface-size", "115"]).makeOptions().interfaceScale, .percent115)
        XCTAssertEqual(try InstallCommand.parse(["a.ipa", "--interface-size", "mac"]).makeOptions().interfaceScale, .macIdiom)
        XCTAssertThrowsError(try InstallCommand.parse(["a.ipa", "--interface-size", "90"]))
    }

    func testUpdateKeepsTheRecordedSizeUnlessOneIsGiven() throws {
        XCTAssertNil(try UpdateCommand.parse(["com.example.app"]).interfaceSize)
        XCTAssertEqual(try UpdateCommand.parse(["com.example.app", "--interface-size", "auto"]).interfaceSize, .auto)
    }

    func testScaleTakesABundleIDAndASizeOrAllAndASize() throws {
        let one = try ScaleCommand.parse(["com.example.app", "100"])
        XCTAssertEqual(one.bundleID, "com.example.app")
        XCTAssertEqual(one.size, .percent100)
        XCTAssertNoThrow(try ScaleCommand.parse(["com.example.app"]))
        XCTAssertNoThrow(try ScaleCommand.parse(["--all", "auto"]))
        XCTAssertNoThrow(try ScaleCommand.parse(["--all"]))
    }

    /// The id becomes a path into the app's container, so it gets the strict check.
    func testScaleRefusesWhatIsNotABundleIDOrASize() {
        XCTAssertThrowsError(try ScaleCommand.parse(["../x", "100"]))
        XCTAssertThrowsError(try ScaleCommand.parse([]))
        XCTAssertThrowsError(try ScaleCommand.parse(["--all", "huge"]))
        XCTAssertThrowsError(try ScaleCommand.parse(["--all", "auto", "100"]))
    }
}
