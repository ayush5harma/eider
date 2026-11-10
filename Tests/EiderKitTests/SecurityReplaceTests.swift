import Foundation
import XCTest
@testable import EiderKit

/// Finding 3: an IPA may not replace an app it has no business replacing.
final class SecurityReplaceTests: XCTestCase {
    private func infoPlist(id: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>\(id)</string>
        <key>CFBundleExecutable</key><string>Exec</string>
        <key>CFBundleName</key><string>Thing</string>
        </dict></plist>
        """
    }

    private func installer(_ scratch: EngineScratch) throws -> Installer {
        let shims = ShimLocator(environment: [ShimLocator.overrideVariable: try scratch.placeholderShims().path], executableURL: nil, resourceURL: nil)
        return Installer(paths: EiderPaths(home: scratch.url("home")), shims: shims)
    }

    private func ipa(_ scratch: EngineScratch, shipping id: String) throws -> URL {
        let url = scratch.url("thing.ipa")
        try CraftedZip.write([
            CraftedZip.Entry(name: "Payload/Thing.app/Info.plist", text: infoPlist(id: id)),
            CraftedZip.Entry(name: "Payload/Thing.app/Exec", text: "not a binary"),
        ], to: url)
        return url
    }

    private func failure(_ scratch: EngineScratch, _ ipa: URL, _ options: InstallOptions) async throws -> InstallFailure {
        do {
            _ = try await installer(scratch).install(ipa: ipa, options: options)
            XCTFail("expected a refusal")
        } catch let failure as InstallFailure {
            return failure
        }
        throw XCTSkip("unreachable")
    }

    // MARK: The IPA must be the app the catalog named

    func testAnIPAWithAnotherBundleIDIsRefusedBeforeAnythingIsTouched() async throws {
        let scratch = try EngineScratch()
        let destination = scratch.url("apps")
        let options = InstallOptions(destination: destination, expectedBundleID: "com.listed.app")
        let refusal = try await failure(scratch, try ipa(scratch, shipping: "com.victim.app"), options)
        XCTAssertEqual(refusal.code, .bundleIDMismatch, refusal.message)
        XCTAssertTrue(refusal.message.contains("com.listed.app") && refusal.message.contains("com.victim.app"), refusal.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testTheExpectedIDOrTheExplicitOverrideGetsPastTheCheck() async throws {
        // Past the check the fake binary fails later, at the Mach-O stage: that is the evidence.
        let scratch = try EngineScratch()
        let matching = InstallOptions(destination: scratch.url("apps"), expectedBundleID: "com.listed.app")
        let same = try await failure(scratch, try ipa(scratch, shipping: "com.listed.app"), matching)
        XCTAssertEqual(same.code, .noMachO, same.message)

        let overridden = InstallOptions(destination: scratch.url("apps"), bundleID: "com.victim.app", expectedBundleID: "com.listed.app")
        let override = try await failure(scratch, try ipa(scratch, shipping: "com.victim.app"), overridden)
        XCTAssertEqual(override.code, .noMachO, override.message)
    }

    // MARK: A bundle at the destination is replaced only when it is Eider's own

    private func placer(recorded: [InstalledApp], force: Bool = false, trashed: [URL] = []) -> (AppPlacer, TrashLog) {
        let log = TrashLog()
        let placer = AppPlacer(
            force: force, resetData: false, reset: DataReset(containersDirectory: URL(fileURLWithPath: "/nonexistent"), isRunning: { _ in false }),
            recorded: recorded, trash: { log.add($0) }, emit: { _, _ in })
        return (placer, log)
    }

    private func bundle(_ scratch: EngineScratch, _ path: String, id: String) throws -> URL {
        let url = scratch.url(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(infoPlist(id: id).utf8).write(to: url.appendingPathComponent("Info.plist"))
        return url
    }

    private func record(_ id: String, at path: URL) -> InstalledApp {
        InstalledApp(bundleID: id, name: "Thing", version: "1", build: "1", path: path, options: InstallOptions())
    }

    func testABundleEiderDidNotInstallNeedsForceEvenWithTheSameBundleID() throws {
        let scratch = try EngineScratch()
        let existing = try bundle(scratch, "apps/Thing.app", id: "com.same.id")
        let fresh = try bundle(scratch, "work/Thing.app", id: "com.same.id")
        let (placer, log) = placer(recorded: [])
        XCTAssertThrowsError(try placer.place(fresh, name: "Thing", bundleID: "com.same.id", into: scratch.url("apps"))) {
            XCTAssertEqual(($0 as? InstallFailure)?.code, .destinationConflict, "\($0)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: existing.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertEqual(log.urls, [])
    }

    func testABundleRecordedForAnotherIDOrAnotherPathNeedsForce() throws {
        let scratch = try EngineScratch()
        let existing = try bundle(scratch, "apps/Thing.app", id: "com.same.id")
        let fresh = try bundle(scratch, "work/Thing.app", id: "com.same.id")
        for recorded in [record("com.other.id", at: existing), record("com.same.id", at: scratch.url("elsewhere/Thing.app"))] {
            let (placer, _) = placer(recorded: [recorded])
            XCTAssertThrowsError(try placer.place(fresh, name: "Thing", bundleID: "com.same.id", into: scratch.url("apps"))) {
                XCTAssertEqual(($0 as? InstallFailure)?.code, .destinationConflict, "\($0)")
            }
        }
    }

    func testEidersOwnRecordedBundleIsReplacedWithoutForce() throws {
        let scratch = try EngineScratch()
        let existing = try bundle(scratch, "apps/Thing.app", id: "com.same.id")
        let fresh = try bundle(scratch, "work/Thing.app", id: "com.same.id")
        let (placer, log) = placer(recorded: [record("com.same.id", at: existing)])
        let target = try placer.place(fresh, name: "Thing", bundleID: "com.same.id", into: scratch.url("apps"))
        XCTAssertEqual(target.lastPathComponent, "Thing.app")
        XCTAssertEqual(log.urls.map(\.path), [existing.path])
    }

    func testForceReplacesAForeignBundle() throws {
        let scratch = try EngineScratch()
        let existing = try bundle(scratch, "apps/Thing.app", id: "com.someone.else")
        let fresh = try bundle(scratch, "work/Thing.app", id: "com.same.id")
        let (placer, log) = placer(recorded: [], force: true)
        _ = try placer.place(fresh, name: "Thing", bundleID: "com.same.id", into: scratch.url("apps"))
        XCTAssertEqual(log.urls.map(\.path), [existing.path])
    }
}

/// A stand-in for the Trash: what is sent there is recorded and moved into `bin`
/// (or removed, when there is none), so the placement that follows finds a free name.
final class TrashLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []
    private let bin: URL?
    init(bin: URL? = nil) { self.bin = bin }
    var urls: [URL] { lock.withLock { _urls } }

    @discardableResult
    func add(_ url: URL) -> URL? {
        lock.withLock { _urls.append(url) }
        guard let bin else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let moved = bin.appendingPathComponent(UUID().uuidString).appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: url, to: moved)
        return moved
    }
}
