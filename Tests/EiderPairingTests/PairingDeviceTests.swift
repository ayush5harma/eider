import Foundation
import XCTest
@testable import EiderPairing

/// The whole flow against a real iPhone, from the Mac. Skipped unless both are set:
///
///   EIDER_PAIRING_FILE  an RP pairing file for the phone (keep it outside the repository)
///   EIDER_PAIRING_HOST  the phone's address, e.g. its Wi-Fi IP (port 49152)
///
/// Optional: EIDER_PAIRING_IPA (default /tmp/eider-probe/probe.ipa), EIDER_PAIRING_BUNDLE_ID
/// (default the probe's id) and EIDER_PAIRING_UDID, which turns on the devicectl cross-check.
/// The test installs that one IPA, confirms it, uninstalls it and confirms it is gone; it
/// changes nothing else on the device.
final class PairingDeviceTests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    func testCheckInstallAndUninstallOnDevice() async throws {
        guard let path = environment["EIDER_PAIRING_FILE"], let host = environment["EIDER_PAIRING_HOST"] else {
            throw XCTSkip("set EIDER_PAIRING_FILE and EIDER_PAIRING_HOST to run against a device")
        }
        let ipa = URL(fileURLWithPath: environment["EIDER_PAIRING_IPA"] ?? "/tmp/eider-probe/probe.ipa")
        let bundleID = environment["EIDER_PAIRING_BUNDLE_ID"] ?? "io.github.ayush5harma.EiderInstallProbe"
        let udid = environment["EIDER_PAIRING_UDID"]

        let file = try RemotePairingFile(data: Data(contentsOf: URL(fileURLWithPath: path)))
        let installer = PairingInstaller(pairingFile: file, host: host)

        var start = Date()
        let reachability = await installer.check()
        print("check: \(reachability) in \(Self.seconds(since: start))")
        XCTAssertEqual(reachability, .ready)
        guard reachability == .ready else { return }

        // A pairing the phone never made: pair-verify fails and is reported, with no
        // pair-setup and so no Trust prompt on the phone.
        let stranger = PairingInstaller(pairingFile: try PairingInstallerTests.freshPairingFile(), host: host)
        let refused = await stranger.check()
        print("check with an unknown pairing file: \(refused)")
        XCTAssertEqual(refused, .refused("the iPhone did not accept this pairing file (pair-verify failed)"))

        if let udid {
            XCTAssertFalse(try Self.isInstalled(bundleID, on: udid), "\(bundleID) was already installed")
        }

        let seen = Recorder()
        start = Date()
        try await installer.install(ipa: ipa, bundleID: bundleID) { seen.append($0) }
        print("install: \(Self.seconds(since: start)), \(seen.values.count) progress events, "
              + "first \(seen.values.first.map(String.init(describing:)) ?? "-"), "
              + "last upload \(seen.values.last { if case .uploading = $0 { true } else { false } }.map(String.init(describing:)) ?? "-")")
        XCTAssertEqual(seen.values.first, .connecting)
        XCTAssertEqual(seen.values.last, .finished)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: ipa.path)[.size] as? Int64)
        XCTAssertTrue(seen.values.contains(.uploading(sent: size, total: size)))

        if let udid {
            let installed = try Self.isInstalled(bundleID, on: udid)
            print("devicectl after install: installed=\(installed)")
            XCTAssertTrue(installed)
        }

        start = Date()
        try await installer.uninstall(bundleID: bundleID)
        print("uninstall: \(Self.seconds(since: start))")
        if let udid {
            let installed = try Self.isInstalled(bundleID, on: udid)
            print("devicectl after uninstall: installed=\(installed)")
            XCTAssertFalse(installed)
        }
    }

    private static func seconds(since start: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(start))
    }

    /// `xcrun devicectl device info apps --bundle-id`, read from its JSON output.
    private static func isInstalled(_ bundleID: String, on udid: String) throws -> Bool {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("devicectl-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["devicectl", "device", "info", "apps", "--device", udid,
                             "--bundle-id", bundleID, "--json-output", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any]
        let result = json?["result"] as? [String: Any]
        let apps = try XCTUnwrap(result?["apps"] as? [[String: Any]], "devicectl gave no app list")
        return apps.contains { $0["bundleIdentifier"] as? String == bundleID }
    }
}
