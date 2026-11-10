import XCTest
@testable import EiderKit

final class EiderPathsTests: XCTestCase {
    func testHomeOverrideMovesEveryPath() {
        let paths = EiderPaths(environment: ["EIDER_HOME": "/tmp/eider-test-home"])
        XCTAssertEqual(paths.home.path, "/tmp/eider-test-home")
        XCTAssertEqual(paths.libraryFile.path, "/tmp/eider-test-home/library.json")
        XCTAssertEqual(paths.downloads.path, "/tmp/eider-test-home/Downloads")
    }

    func testSha256OfAKnownFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("eider-hash-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(
            try Hashing.sha256(ofFileAt: file),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
