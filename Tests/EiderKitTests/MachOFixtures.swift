import Foundation
import XCTest
@testable import EiderKit

/// Builds tiny binaries at test time with Xcode's clang. The library under
/// test never calls these tools; the tests use them to build inputs and to
/// cross-check the reader against otool and vtool. Missing tools skip.
final class MachOFixtures {
    let directory: URL

    init() throws {
        guard FileManager.default.fileExists(atPath: "/usr/bin/xcrun"),
              let clang = try? ProcessRunner.run("/usr/bin/xcrun", ["--find", "clang"]), clang.succeeded else {
            throw XCTSkip("Xcode command line tools are not available")
        }
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eider-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    @discardableResult
    func tool(_ name: String, _ arguments: [String]) throws -> String {
        let result = try ProcessRunner.run("/usr/bin/xcrun", [name] + arguments)
        guard result.succeeded else { throw XCTSkip("\(name) \(arguments.joined(separator: " ")) failed: \(result.errorLine)") }
        return result.output
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// Compile `source` into `name`; `arguments` are extra clang flags.
    func compile(_ name: String, source: String, _ arguments: [String]) throws -> URL {
        let sourceURL = url("\(name).c")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let out = url(name)
        let targeting = arguments.contains("-arch") ? ["-mmacosx-version-min=14.0"] : ["-target", "arm64-apple-macos14.0"]
        // ld leaves only 32 spare header bytes by default; real apps are linked with more, so the fixtures ask for it.
        try tool("clang", targeting + ["-Wl,-headerpad,0x400"] + arguments + ["-o", out.path, sourceURL.path])
        return out
    }

    func dylib(_ name: String, installName: String? = nil, source: String = "int f(void) { return 1; }\n", _ arguments: [String] = []) throws -> URL {
        try compile(name, source: source, ["-dynamiclib", "-install_name", installName ?? "@rpath/\(name)"] + arguments)
    }

    func sign(_ url: URL) throws {
        let result = try ProcessRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", url.path])
        XCTAssertTrue(result.succeeded, "codesign -f: \(result.errorLine)")
        let verify = try ProcessRunner.run("/usr/bin/codesign", ["--verify", "--strict", url.path])
        XCTAssertTrue(verify.succeeded, "codesign --verify: \(verify.errorLine)")
    }
}
