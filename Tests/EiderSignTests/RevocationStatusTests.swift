import XCTest
@testable import EiderSign

/// OCSP end to end without a network: the request EiderSign builds is
/// answered by `openssl ocsp` acting as the CA's responder.
final class RevocationStatusTests: XCTestCase {
    private var material: TestMaterial!
    private var certificate: SigningCertificate!

    override func setUpWithError() throws {
        material = try TestMaterial()
        let identity = try material.makeIdentity()
        certificate = try SigningCertificate(
            p12: identity.p12, password: TestMaterial.password, provisioningProfile: identity.profile)
    }

    override func tearDown() {
        material = nil
        certificate = nil
    }

    func testGood() async throws {
        try writeIndex(status: "V", revoked: "")
        let asked = AskedURL()
        let status = await certificate.revocationStatus(send: responder(signedBy: material.directory, asked: asked))
        XCTAssertEqual(status, .good)
        XCTAssertEqual(asked.url, URL(string: "http://127.0.0.1:9/ocsp"), "the responder named in the certificate's AIA")
    }

    func testRevoked() async throws {
        try writeIndex(status: "R", revoked: "261101093000Z")
        let status = await certificate.revocationStatus(send: responder(signedBy: material.directory))
        XCTAssertEqual(status, .revoked(Date(timeIntervalSince1970: 1_793_525_400))) // 2026-11-01 09:30:00 UTC
    }

    func testAResponseFromAnotherCAIsNotTrusted() async throws {
        try writeIndex(status: "V", revoked: "")
        let impostor = try TestMaterial()
        try FileManager.default.copyItem(at: material.url("index.txt"), to: impostor.url("index.txt"))
        let status = await certificate.revocationStatus(send: responder(signedBy: impostor.directory))
        withExtendedLifetime(impostor) {} // its folder is deleted on deinit
        guard case .unknown(let reason) = status else { return XCTFail("\(status)") }
        XCTAssertEqual(reason, "The OCSP response is not signed by the certificate's issuer.")
    }

    func testADelegatedResponderIsTrusted() async throws {
        try writeIndex(status: "V", revoked: "")
        try material.makeLeaf("responder", commonName: "Eider Test OCSP Responder", extensions: "responder")
        let status = await certificate.revocationStatus(send: responder(signedBy: material.directory, signer: "responder"))
        XCTAssertEqual(status, .good)
    }

    func testAnotherLeafOfTheSameCAIsNotAResponder() async throws {
        try writeIndex(status: "V", revoked: "")
        // Someone else's code-signing certificate from the same issuer: no OCSPSigning EKU.
        try material.makeLeaf("neighbour", commonName: "Apple Development: Someone Else (EIDRTEST02)")
        let status = await certificate.revocationStatus(send: responder(signedBy: material.directory, signer: "neighbour"))
        XCTAssertEqual(status, .unknown("The OCSP response is not signed by the certificate's issuer."))
    }

    func testAP12ChainThatDidNotSignTheLeafIsNotUsedAsTheIssuer() async throws {
        // A fake CA with the real one's name and key identifier but its own key,
        // shipped in the p12 instead of the real CA: trusting it would let
        // whoever holds that key answer for the leaf.
        let text = try material.openssl("x509", "-in", "ca.crt", "-noout", "-text")
        let lines = text.components(separatedBy: "\n")
        let index = try XCTUnwrap(lines.firstIndex { $0.contains("X509v3 Subject Key Identifier") })
        let keyID = lines[index + 1].trimmingCharacters(in: .whitespaces)
        try """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = Eider Test CA
        O = Eider Tests
        [fake]
        basicConstraints = critical,CA:TRUE
        keyUsage = critical,keyCertSign,cRLSign,digitalSignature
        subjectKeyIdentifier = \(keyID)

        """.write(to: material.url("fake.cnf"), atomically: true, encoding: .utf8)
        try material.openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "fake.key", "-out", "fake.crt",
                             "-days", "30", "-config", "fake.cnf", "-extensions", "fake")
        let p12 = try material.makeP12("leaf", chain: "fake.crt")
        let profile = try material.makeProfile(certificates: [Data(contentsOf: material.url("leaf.der"))])

        let forged = try SigningCertificate(p12: p12, password: TestMaterial.password, provisioningProfile: profile)

        XCTAssertNil(forged.issuerCertificateDER)
        let status = await forged.revocationStatus { _, _ in
            XCTFail("no request without a trusted issuer")
            return Data()
        }
        XCTAssertEqual(status, .unknown("The certificate's issuer is not known, so its status cannot be checked."))
    }

    func testUnreachableResponderIsUnknown() async throws {
        let status = await certificate.revocationStatus { _, _ in throw URLError(.notConnectedToInternet) }
        guard case .unknown(let reason) = status else { return XCTFail("\(status)") }
        XCTAssertTrue(reason.hasPrefix("The OCSP responder could not be reached"), reason)
    }

    func testGarbageIsUnknown() async throws {
        let status = await certificate.revocationStatus { _, _ in Data("<html>captive portal</html>".utf8) }
        XCTAssertEqual(status, .unknown("The OCSP responder sent something that is not an OCSP response."))
    }

    // MARK: - Helpers

    private final class AskedURL: @unchecked Sendable {
        var url: URL?
    }

    /// An openssl index.txt line for the test leaf.
    private func writeIndex(status: String, revoked: String) throws {
        let serial = try material.openssl("x509", "-in", "leaf.crt", "-noout", "-serial")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "serial=", with: "")
        let subject = "/UID=\(TestMaterial.team)/CN=Apple Development: Eider Test (\(TestMaterial.team))"
        let line = [status, "301231235959Z", revoked, serial, "unknown", subject].joined(separator: "\t") + "\n"
        try line.write(to: material.url("index.txt"), atomically: true, encoding: .utf8)
    }

    /// Answers with the CA (or impostor CA) in `directory` as the responder.
    private func responder(signedBy directory: URL, signer: String = "ca", asked: AskedURL = AskedURL())
        -> @Sendable (URL, Data) async throws -> Data
    {
        { url, request in
            asked.url = url
            let name = UUID().uuidString
            try request.write(to: directory.appendingPathComponent("\(name).req"))
            try TestMaterial.run("/usr/bin/openssl", [
                "ocsp", "-index", "index.txt", "-CA", "ca.crt", "-rsigner", "\(signer).crt", "-rkey", "\(signer).key",
                "-reqin", "\(name).req", "-respout", "\(name).resp", "-ndays", "1",
            ], in: directory)
            return try Data(contentsOf: directory.appendingPathComponent("\(name).resp"))
        }
    }
}
