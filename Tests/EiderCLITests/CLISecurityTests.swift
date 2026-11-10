import ArgumentParser
import Foundation
import XCTest
@testable import eider

/// Finding 12 (a file in the working directory beat a bundle id) and the command-line
/// half of finding 2 (a bundle id typed as an argument becomes a path).
final class CLISecurityTests: XCTestCase {
    func testABareNameIsABundleIDEvenWhenAFileOfThatNameExists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eider-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = FileManager.default.currentDirectoryPath
        XCTAssertTrue(FileManager.default.changeCurrentDirectoryPath(directory.path))
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        try Data("not an ipa".utf8).write(to: directory.appendingPathComponent("com.example.app"))

        XCTAssertEqual(InstallCommand.resolve("com.example.app"), .catalog("com.example.app"))
    }

    func testAPathIsAPathWhetherOrNotItExists() {
        XCTAssertEqual(InstallCommand.resolve("./app.ipa"), .localFile(URL(fileURLWithPath: "./app.ipa")))
        XCTAssertEqual(InstallCommand.resolve("dir/app"), .localFile(URL(fileURLWithPath: "dir/app")))
        XCTAssertEqual(InstallCommand.resolve("App.IPA"), .localFile(URL(fileURLWithPath: "App.IPA")))
        XCTAssertEqual(InstallCommand.resolve("~/Downloads/x"), .localFile(URL(fileURLWithPath: ("~/Downloads/x" as NSString).expandingTildeInPath)))
    }

    func testAddressesAndLinksStayAddresses() {
        XCTAssertEqual(InstallCommand.resolve("https://example.com/a.ipa"), .address(URL(string: "https://example.com/a.ipa")!))
        XCTAssertEqual(InstallCommand.resolve("eider://install/https://example.com/a.ipa"), .address(URL(string: "https://example.com/a.ipa")!))
    }

    func testABundleIDArgumentIsValidatedLikeAnyOther() {
        XCTAssertNoThrow(try requireBundleID("com.example.app"))
        for bad in [".", "..", "../Documents", "a/b", ""] {
            XCTAssertThrowsError(try requireBundleID(bad), bad)
        }
    }
}
