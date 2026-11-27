import Foundation
import Security
import XCTest
@testable import EiderInstall

final class LocalRootAuthorityTests: XCTestCase {
    private var keychain: TemporaryKeychain!
    private var scratch: URL!

    override func setUpWithError() throws {
        keychain = try TemporaryKeychain()
        scratch = keychain.directory
    }

    override func tearDown() {
        keychain?.delete()
    }

    private func authority(now: @escaping @Sendable () -> Date = { Date() }) -> LocalRootAuthority {
        LocalRootAuthority(namespace: "test.eider.install", keychain: keychain.scope, now: now)
    }

    private func write(_ der: Data, _ name: String) throws -> String {
        let url = scratch.appendingPathComponent(name)
        try pem(der).write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func testRootAndLeafHaveTheRequiredExtensionsAndVerify() async throws {
        let authority = authority()
        let created = try await authority.hasRoot()
        XCTAssertFalse(created)

        let root = try await authority.rootCertificate()
        let server = try await authority.serverIdentity()
        XCTAssertEqual(server.root, root)
        let rootPath = try write(root, "root.pem")
        let leafPath = try write(server.leaf, "leaf.pem")

        let rootText = try runTool(opensslPath, ["x509", "-in", rootPath, "-noout", "-text"]).output
        XCTAssertTrue(rootText.contains("Subject: CN=Eider Local Install ("), rootText)
        XCTAssertTrue(rootText.contains("O=Eider") || rootText.contains("O = Eider"), rootText)
        XCTAssertTrue(rootText.contains("X509v3 Basic Constraints: critical"), rootText)
        XCTAssertTrue(rootText.contains("CA:TRUE, pathlen:0"), rootText)
        XCTAssertTrue(rootText.contains("X509v3 Key Usage: critical"), rootText)
        XCTAssertTrue(rootText.contains("Certificate Sign, CRL Sign"), rootText)
        XCTAssertTrue(rootText.contains("X509v3 Name Constraints: critical"), rootText)
        XCTAssertTrue(rootText.contains("DNS:localhost"), rootText)
        XCTAssertTrue(rootText.contains("IP:127.0.0.1/255.255.255.255"), rootText)

        let leafText = try runTool(opensslPath, ["x509", "-in", leafPath, "-noout", "-text"]).output
        XCTAssertTrue(leafText.contains("Subject: CN=Eider local server"), leafText)
        XCTAssertTrue(leafText.contains("IP Address:127.0.0.1"), leafText)
        XCTAssertTrue(leafText.contains("DNS:localhost"), leafText)
        XCTAssertTrue(leafText.contains("TLS Web Server Authentication"), leafText)
        XCTAssertTrue(leafText.contains("CA:FALSE"), leafText)

        let verify = try runTool(opensslPath, ["verify", "-CAfile", rootPath, leafPath])
        XCTAssertEqual(verify.status, 0, verify.output)
        XCTAssertTrue(verify.output.contains("OK"), verify.output)

        let days = try runTool(opensslPath, ["x509", "-in", leafPath, "-noout", "-startdate", "-enddate"]).output
        XCTAssertFalse(days.isEmpty)
    }

    func testAppleTrustAcceptsTheLeafForLoopbackOnly() async throws {
        let authority = authority()
        let server = try await authority.serverIdentity()
        let root = try LocalRootAuthority.secCertificate(server.root)
        let leaf = try LocalRootAuthority.secCertificate(server.leaf)

        func evaluate(host: String) -> Bool {
            var trust: SecTrust?
            SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust)
            SecTrustSetAnchorCertificates(trust!, [root] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust!, true)
            return SecTrustEvaluateWithError(trust!, nil)
        }
        XCTAssertTrue(evaluate(host: "127.0.0.1"))
        XCTAssertTrue(evaluate(host: "localhost"))
        XCTAssertFalse(evaluate(host: "example.com"))
    }

    func testIdentityIsReusedThenReissuedNearExpiry() async throws {
        let first = try await authority().serverIdentity()
        let again = try await authority().serverIdentity()
        XCTAssertEqual(first.leaf, again.leaf)

        // 280 days on, the 300-day leaf has 20 days left: under the 30-day window.
        let later = authority(now: { Date().addingTimeInterval(280 * 86_400) })
        let renewed = try await later.serverIdentity()
        XCTAssertNotEqual(renewed.leaf, first.leaf)
        XCTAssertEqual(renewed.root, first.root)
    }

    func testLeafIsReissuedWhenTheRootChanges() async throws {
        let first = try await authority().serverIdentity()
        // Replace only the root, as if its items had been lost; the old leaf stays behind.
        let store = KeychainStore(scope: keychain.scope)
        try store.deleteCertificates(label: "test.eider.install.root")
        try store.deleteKeys(tag: "test.eider.install.root.key")

        let second = try await authority().serverIdentity()
        XCTAssertNotEqual(second.root, first.root)
        XCTAssertNotEqual(second.leaf, first.leaf)
        let verify = try runTool(opensslPath, ["verify", "-CAfile", try write(second.root, "r2.pem"),
                                           try write(second.leaf, "l2.pem")])
        XCTAssertEqual(verify.status, 0, verify.output)
    }

    func testMobileconfigCarriesTheRoot() async throws {
        let authority = authority()
        let profile = try await authority.mobileconfig()
        let root = try await authority.rootCertificate()
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: profile, format: nil) as? [String: Any])
        XCTAssertEqual(plist["PayloadType"] as? String, "Configuration")
        XCTAssertEqual(plist["PayloadDisplayName"] as? String, "Eider Local Install")
        let payload = try XCTUnwrap((plist["PayloadContent"] as? [[String: Any]])?.first)
        XCTAssertEqual(payload["PayloadType"] as? String, "com.apple.security.root")
        XCTAssertEqual(payload["PayloadContent"] as? Data, root)
        XCTAssertNotNil(UUID(uuidString: payload["PayloadUUID"] as? String ?? ""))

        // The same root yields the same profile, so installing it again replaces it.
        let again = try await authority.mobileconfig()
        XCTAssertEqual(again, profile)
    }
}
