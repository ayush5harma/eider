import Foundation
import XCTest
@testable import EiderKit

/// Finding 11: a nested bundle that fails to sign is reported, not swallowed.
final class SecuritySigningTests: XCTestCase {
    func testANestedBundleThatWillNotSignIsReportedAndTheFinalVerifyStillRuns() throws {
        let fixtures = try MachOFixtures()
        let app = fixtures.url("App.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Bad.bundle"), withIntermediateDirectories: true)
        let executable = try fixtures.compile("Exec", source: "int main(void) { return 0; }\n", [])
        try FileManager.default.copyItem(at: executable, to: app.appendingPathComponent("Exec"))
        let info = ["CFBundleIdentifier": "test.sign", "CFBundleExecutable": "Exec", "CFBundleName": "App"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        // A bundle whose Info.plist is not a plist: codesign refuses it.
        try Data("garbage".utf8).write(to: app.appendingPathComponent("Bad.bundle/Info.plist"))

        let signer = BundleSigner(app: app, workDirectory: fixtures.directory, relative: { $0.lastPathComponent })
        let warnings = WarningBox()
        try signer.sign(machOs: [app.appendingPathComponent("Exec")], warn: { warnings.add($0) })

        XCTAssertEqual(warnings.lines.count, 1, "\(warnings.lines)")
        XCTAssertTrue(warnings.lines.first?.contains("Bad.bundle") == true, "\(warnings.lines)")
        XCTAssertNoThrow(try signer.verify(machOs: [app.appendingPathComponent("Exec")]), "the strict verify is still the gate")
    }
}

private final class WarningBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func add(_ line: String) { lock.withLock { _lines.append(line) } }
}
