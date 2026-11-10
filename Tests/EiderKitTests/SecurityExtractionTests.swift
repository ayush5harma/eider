import Foundation
import XCTest
@testable import EiderKit

/// Findings 1 and 4: extraction may not write outside its directory through a
/// symlink (including on a case-insensitive volume), and the size cap counts
/// bytes actually written, not what the central directory claims.
final class SecurityExtractionTests: XCTestCase {
    private let plist = CraftedZip.Entry(name: "Payload/A.app/Info.plist", text: "x")

    /// scratch/work/x is the extraction directory, so "../../../../outside" from
    /// Payload/A.app lands in scratch/outside, which must stay empty.
    private func attempt(_ entries: [CraftedZip.Entry], cap: UInt64 = IPAExtractor.defaultMaxUncompressedBytes) throws -> (scratch: EngineScratch, outside: URL, result: Result<URL, Error>) {
        let scratch = try EngineScratch()
        let ipa = scratch.url("evil.ipa")
        try CraftedZip.write(entries, to: ipa)
        let outside = scratch.url("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = scratch.url("work/x")
        let result = Result { try IPAExtractor(maxUncompressedBytes: cap).extract(ipa, into: target) }
        return (scratch, outside, result)
    }

    private func assertNothingOutside(_ outside: URL, _ form: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = (try? FileManager.default.contentsOfDirectory(atPath: outside.path)) ?? []
        XCTAssertEqual(found, [], "\(form): a file was written outside the extraction directory", file: file, line: line)
    }

    private func linkOut(_ writer: String) -> [CraftedZip.Entry] {
        [plist,
         CraftedZip.Entry(name: "Payload/A.app/Frameworks", text: "../../../../outside", symlink: true),
         CraftedZip.Entry(name: writer, text: "planted")]
    }

    // MARK: Finding 1

    func testWritingThroughASymlinkLandsNothingOutsideInAnySpelling() throws {
        for (form, writer) in [
            ("plain", "Payload/A.app/Frameworks/x"),
            ("case variant", "Payload/A.app/frameworks/x"),
            ("dot component", "Payload/A.app/./Frameworks/x"),
            ("case variant and dot", "Payload/A.app/./FRAMEWORKS/x"),
            ("doubled slash", "Payload/A.app//Frameworks/x"),
        ] {
            let outcome = try attempt(linkOut(writer))
            assertNothingOutside(outcome.outside, form)
            if case .success = outcome.result { XCTFail("\(form): an archive that writes below a symlink must be refused") }
        }
    }

    func testASymlinkWithAnEscapingOrAbsoluteTargetIsRefusedAndNeverCreated() throws {
        for target in ["../../../../outside", "/tmp", "data/../x", "..", ""] {
            let outcome = try attempt([plist, CraftedZip.Entry(name: "Payload/A.app/link", text: target, symlink: true)])
            guard case .failure(let error) = outcome.result else { return XCTFail("\(target): expected a refusal") }
            XCTAssertEqual((error as? InstallFailure)?.code, .unsafeArchive, "\(target): \(error)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: outcome.scratch.url("work/x/Payload/A.app/link").path))
        }
    }

    func testARelativeInBundleSymlinkIsRecreatedAfterExtraction() throws {
        let outcome = try attempt([
            plist,
            CraftedZip.Entry(name: "Payload/A.app/data/real.txt", text: "hello"),
            CraftedZip.Entry(name: "Payload/A.app/link", text: "data/real.txt", symlink: true),
        ])
        let app = try outcome.result.get()
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: app.appendingPathComponent("link").path), "data/real.txt")
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("link")), "hello")
        assertNothingOutside(outcome.outside, "legitimate link")
    }

    func testASymlinkNamedLikeARegularFileIsRefused() throws {
        let outcome = try attempt([
            plist,
            CraftedZip.Entry(name: "Payload/A.app/Thing", text: "file"),
            CraftedZip.Entry(name: "Payload/A.app/thing", text: "Info.plist", symlink: true),
        ])
        guard case .failure(let error) = outcome.result else { return XCTFail("a link may not replace or shadow an extracted entry") }
        XCTAssertEqual((error as? InstallFailure)?.code, .unsafeArchive, "\(error)")
    }

    // MARK: Finding 4

    func testTheSizeCapCountsBytesWrittenNotTheClaimedSize() throws {
        let cap: UInt64 = 5 << 20
        let bomb = CraftedZip.Entry(name: "Payload/A.app/bomb.bin", zeros: 400 << 20, claimedSize: 100)
        let scratch = try EngineScratch()
        let ipa = scratch.url("bomb.ipa")
        try CraftedZip.write([plist, bomb], to: ipa)
        let target = scratch.url("work/x")
        let started = Date()
        XCTAssertThrowsError(try IPAExtractor(maxUncompressedBytes: cap).extract(ipa, into: target)) {
            XCTAssertEqual(($0 as? InstallFailure)?.code, .tooLarge, "\($0)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "what was written is removed")
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
    }

    func testARunningProgramIsTerminatedWhenTheWatchSaysSo() throws {
        let started = Date()
        let result = try ProcessRunner.run("/bin/sleep", ["30"], pollEvery: 0.05, stopWhen: { true })
        XCTAssertTrue(result.stopped)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
