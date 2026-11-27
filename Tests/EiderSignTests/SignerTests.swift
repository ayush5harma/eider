import CryptoKit
import XCTest
@testable import EiderSign

final class SignerTests: XCTestCase {
    private var material: TestMaterial!

    override func setUpWithError() throws {
        material = try TestMaterial()
    }

    override func tearDown() {
        material = nil
    }

    private func certificate(appID: String = "\(TestMaterial.team).*") throws -> SigningCertificate {
        let identity = try material.makeIdentity(appID: appID)
        return try SigningCertificate(p12: identity.p12, password: TestMaterial.password, provisioningProfile: identity.profile)
    }

    func testSignsTheAppItsExtensionAndItsDylib() async throws {
        let app = try ProbeApp.build(in: material.directory)
        let certificate = try certificate()

        try await Signer.sign(appAt: app, certificate: certificate)

        let details = try codesign(["-dvvv", app.path])
        XCTAssertTrue(details.contains("Identifier=\(ProbeApp.bundleIdentifier)\n"), details)
        XCTAssertTrue(details.contains("TeamIdentifier=\(TestMaterial.team)\n"), details)
        XCTAssertTrue(details.contains("CodeDirectory v=20400 "), details)
        XCTAssertTrue(details.contains("Hash choices=sha1,sha256\n"), details)
        XCTAssertTrue(details.contains("Sealed Resources version=2 "), details)
        try assertCMSVerifies(app.appendingPathComponent("Probe"))
        // Special slot -1 binds Info.plist (codesign prints "not bound" only
        // because it cannot evaluate the untrusted test chain).
        let slots = try codesign(["-d", "--verbose=6", app.path])
        let infoHash = SHA256.hash(data: try Data(contentsOf: app.appendingPathComponent("Info.plist")))
        XCTAssertTrue(slots.contains("-1=\(infoHash.map { String(format: "%02x", $0) }.joined())"), slots)

        let entitlements = try signedEntitlements(app)
        XCTAssertEqual(entitlements["application-identifier"] as? String, "\(TestMaterial.team).\(ProbeApp.bundleIdentifier)")
        XCTAssertEqual(entitlements["com.apple.developer.team-identifier"] as? String, TestMaterial.team)
        XCTAssertEqual(entitlements["get-task-allow"] as? Bool, true)

        let widget = app.appendingPathComponent("PlugIns/Widget.appex")
        let widgetDetails = try codesign(["-dvvv", widget.path])
        XCTAssertTrue(widgetDetails.contains("Identifier=\(ProbeApp.bundleIdentifier).widget\n"), widgetDetails)
        XCTAssertEqual(
            try signedEntitlements(widget)["application-identifier"] as? String,
            "\(TestMaterial.team).\(ProbeApp.bundleIdentifier).widget",
            "each executable gets its own application-identifier, not TEAM.*")

        let dylib = app.appendingPathComponent("Frameworks/libEiderProbe.dylib")
        let dylibDetails = try codesign(["-dvvv", dylib.path])
        XCTAssertTrue(dylibDetails.contains("Hash choices=sha1,sha256\n"), dylibDetails)
        // The linker's ad hoc signature was replaced.
        XCTAssertFalse(dylibDetails.contains("Signature=adhoc"), dylibDetails)
        try assertCMSVerifies(dylib)
        try assertCMSVerifies(widget.appendingPathComponent("Widget"))

        XCTAssertEqual(try Data(contentsOf: app.appendingPathComponent("embedded.mobileprovision")), certificate.profileData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("_CodeSignature/CodeResources").path))
        // Unchanged without options.
        let info = try ProbeApp.info(app)
        XCTAssertNotNil(info["UISupportedDevices"])
        XCTAssertNotNil(info["CFBundleURLTypes"])
    }

    func testAppliesTheSigningOptions() async throws {
        let app = try ProbeApp.build(in: material.directory)
        let options = SigningOptions(
            bundleIdentifier: "com.example.renamed",
            displayName: "Renamed",
            version: "2.5",
            removeSupportedDevices: true,
            enableFileSharing: true,
            removeURLSchemes: true)

        try await Signer.sign(appAt: app, certificate: certificate(), options: options)

        let info = try ProbeApp.info(app)
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.example.renamed")
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Renamed")
        XCTAssertEqual(info["CFBundleName"] as? String, "Renamed")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "2.5")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "2.5")
        XCTAssertNil(info["UISupportedDevices"])
        XCTAssertNil(info["CFBundleURLTypes"])
        XCTAssertEqual(info["UIFileSharingEnabled"] as? Bool, true)
        XCTAssertEqual(info["UISupportsDocumentBrowser"] as? Bool, true)
        XCTAssertEqual(try ProbeApp.info(app, "PlugIns/Widget.appex")["CFBundleIdentifier"] as? String, "com.example.renamed.widget")

        let details = try codesign(["-dvvv", app.path])
        XCTAssertTrue(details.contains("Identifier=com.example.renamed\n"), details)
        XCTAssertEqual(try signedEntitlements(app)["application-identifier"] as? String, "\(TestMaterial.team).com.example.renamed")
        XCTAssertEqual(
            try signedEntitlements(app.appendingPathComponent("PlugIns/Widget.appex"))["application-identifier"] as? String,
            "\(TestMaterial.team).com.example.renamed.widget")
    }

    func testAnExplicitProfileRefusesAnotherBundleIdentifier() async throws {
        let app = try ProbeApp.build(in: material.directory)
        let explicit = try certificate(appID: "\(TestMaterial.team).com.example.only")

        await assertThrows(
            try await Signer.sign(appAt: app, certificate: explicit),
            .bundleIdentifierNotAllowed(
                bundleIdentifier: ProbeApp.bundleIdentifier, profileName: "Eider Test Wildcard", allowed: "com.example.only"))
        // Renaming the app is not enough: the extension needs its own profile.
        await assertThrows(
            try await Signer.sign(appAt: app, certificate: explicit, options: SigningOptions(bundleIdentifier: "com.example.only")),
            .bundleIdentifierNotAllowed(
                bundleIdentifier: "com.example.only.widget", profileName: "Eider Test Wildcard", allowed: "com.example.only"))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: app.appendingPathComponent("embedded.mobileprovision").path),
            "a refusal leaves the app untouched")
        let message = SigningError.bundleIdentifierNotAllowed(
            bundleIdentifier: "a.b", profileName: "P", allowed: "c.d").errorDescription
        XCTAssertEqual(message, "The provisioning profile \"P\" only signs c.d, not a.b. Change the bundle identifier or use a wildcard profile.")
    }

    func testAnExplicitProfileSignsItsOwnBundleIdentifier() async throws {
        let app = try ProbeApp.build(in: material.directory)
        try FileManager.default.removeItem(at: app.appendingPathComponent("PlugIns"))
        let explicit = try certificate(appID: "\(TestMaterial.team).\(ProbeApp.bundleIdentifier)")

        try await Signer.sign(appAt: app, certificate: explicit)

        XCTAssertEqual(try signedEntitlements(app)["application-identifier"] as? String, "\(TestMaterial.team).\(ProbeApp.bundleIdentifier)")
    }

    func testRefusesSomethingThatIsNotAnApp() async throws {
        let folder = material.url("Empty.app")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await assertThrows(try await Signer.sign(appAt: folder, certificate: certificate()), .notAnApp(path: "Empty.app"))
    }

    func testRefusesAtSigningTimeOnceTheProfileHasExpired() async throws {
        let app = try ProbeApp.build(in: material.directory)
        let certificate = try certificate()
        do {
            try await ZsignEngine.shared.sign(
                appAt: app, certificate: certificate, options: SigningOptions(),
                now: certificate.profileExpires.addingTimeInterval(1))
            XCTFail("signed with an expired profile")
        } catch SigningError.profileExpired {
        }
    }

    // MARK: - Helpers

    private func codesign(_ arguments: [String]) throws -> String {
        try material.run("/usr/bin/codesign", arguments)
    }

    /// The CMS signs the first CodeDirectory, with the test leaf, chaining to
    /// the test CA: what codesign --verify would check against Apple's roots.
    private func assertCMSVerifies(_ binary: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let blobs = try SignatureBlobs(machO: binary)
        guard let cms = blobs.blobs[SignatureBlobs.cms], let codeDirectory = blobs.blobs[SignatureBlobs.codeDirectory] else {
            return XCTFail("\(binary.lastPathComponent) has no CMS or CodeDirectory", file: file, line: line)
        }
        XCTAssertNotNil(blobs.blobs[SignatureBlobs.alternateCodeDirectory], "SHA-256 CodeDirectory", file: file, line: line)
        let name = UUID().uuidString
        try cms.dropFirst(8).write(to: material.url("\(name).cms"))
        try codeDirectory.write(to: material.url("\(name).cd"))
        try material.openssl("cms", "-verify", "-inform", "DER", "-in", "\(name).cms", "-content", "\(name).cd",
                             "-binary", "-CAfile", "ca.crt", "-purpose", "any", "-signer", "\(name).pem", "-out", "/dev/null")
        let signer = try material.openssl("x509", "-in", "\(name).pem", "-noout", "-subject")
        XCTAssertTrue(signer.contains("CN=Apple Development: Eider Test (EIDRTEST01)"), signer, file: file, line: line)
    }

    /// The entitlements blob of the bundle's executable, checked against the
    /// CodeDirectory slot that binds it. Read from the binary because
    /// `codesign -d --entitlements -` withholds them for an untrusted chain
    /// ("binary contains an invalid entitlements blob"); upstream zsign's own
    /// output of the same app gets the same warning (measured 2026-11-28).
    private func signedEntitlements(_ bundle: URL, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let executable = try ProbeApp.info(bundle)["CFBundleExecutable"] as? String ?? ""
        let binary = bundle.appendingPathComponent(executable)
        guard let blob = try SignatureBlobs(machO: binary).blobs[5] else {
            XCTFail("no entitlements blob in \(executable)", file: file, line: line)
            return [:]
        }
        let slotHash = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        let slots = try codesign(["-d", "--verbose=6", binary.path])
        XCTAssertTrue(slots.contains("-5=\(slotHash)"), "slot -5 binds the entitlements: \(slots)", file: file, line: line)
        return try PropertyListSerialization.propertyList(from: blob.dropFirst(8), format: nil) as? [String: Any] ?? [:]
    }

    private func assertThrows(
        _ body: @autoclosure () async throws -> Void,
        _ expected: SigningError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("did not throw \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SigningError, expected, file: file, line: line)
        }
    }
}
