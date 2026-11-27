import Foundation
import XCTest

/// Throwaway signing material made with the system openssl in a fresh temp
/// folder per test: a CA, leaf certificates with the code-signing EKU, p12s
/// and CMS-wrapped provisioning profiles. Nothing here is a real Apple
/// identity and nothing is written into the repository.
final class TestMaterial {
    static let team = "EIDRTEST01"
    static let password = "correct horse battery"
    static let device = "00008150-000A1B2C3D4E5F60"

    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eider-sign-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.config.write(to: url("openssl.cnf"), atomically: true, encoding: .utf8)
        try Self.requestConfig.write(to: url("request.cnf"), atomically: true, encoding: .utf8)
        try openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.crt",
                    "-days", "30", "-config", "openssl.cnf", "-extensions", "v3_ca")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// A leaf issued by the test CA; returns its DER.
    @discardableResult
    func makeLeaf(
        _ name: String,
        commonName: String = "Apple Development: Eider Test (\(TestMaterial.team))",
        extensions: String = "leaf"
    ) throws -> Data {
        let subject = "/UID=\(Self.team)/CN=\(commonName)/OU=\(Self.team)/O=Eider Test Team/C=US"
        try openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", "\(name).key", "-out", "\(name).csr",
                    "-config", "request.cnf", "-subj", subject)
        try openssl("x509", "-req", "-in", "\(name).csr", "-CA", "ca.crt", "-CAkey", "ca.key",
                    "-set_serial", String(UInt32.random(in: 1_000...UInt32.max)), "-days", "30",
                    "-out", "\(name).crt", "-extfile", "openssl.cnf", "-extensions", extensions)
        try openssl("x509", "-in", "\(name).crt", "-outform", "DER", "-out", "\(name).der")
        return try Data(contentsOf: url("\(name).der"))
    }

    /// The leaf and its key, with the CA in the chain, as zsign needs to find
    /// the issuer of a non-Apple certificate.
    func makeP12(
        _ name: String,
        password: String = TestMaterial.password,
        chain: String = "ca.crt",
        mac: Bool = true
    ) throws -> Data {
        try run("/usr/bin/openssl", [
            "pkcs12", "-export", "-inkey", "\(name).key", "-in", "\(name).crt", "-certfile", chain,
            "-name", "Eider Test", "-passout", "pass:\(password)", "-out", "\(name).p12",
        ] + (mac ? [] : ["-nomac"]))
        return try Data(contentsOf: url("\(name).p12"))
    }

    func makeProfile(
        certificates: [Data],
        name: String = "Eider Test Wildcard",
        appID: String = "\(TestMaterial.team).*",
        devices: [String] = [TestMaterial.device],
        allDevices: Bool = false,
        getTaskAllow: Bool? = true,
        expires: Date = Date().addingTimeInterval(20 * 86_400)
    ) throws -> Data {
        var entitlements: [String: Any] = [
            "application-identifier": appID,
            "com.apple.developer.team-identifier": Self.team,
            "keychain-access-groups": ["\(Self.team).*"],
        ]
        if let getTaskAllow { entitlements["get-task-allow"] = getTaskAllow }
        var plist: [String: Any] = [
            "AppIDName": "Eider Test",
            "ApplicationIdentifierPrefix": [Self.team],
            "CreationDate": Date().addingTimeInterval(-86_400),
            "DeveloperCertificates": certificates,
            "Entitlements": entitlements,
            "ExpirationDate": expires,
            "Name": name,
            "Platform": ["iOS"],
            "TeamIdentifier": [Self.team],
            "TeamName": "Eider Test Team",
            "TimeToLive": 20,
            "UUID": UUID().uuidString,
            "Version": 1,
        ]
        if allDevices {
            plist["ProvisionsAllDevices"] = true
        } else if !devices.isEmpty {
            plist["ProvisionedDevices"] = devices
        }
        let file = "profile-\(UUID().uuidString)"
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try xml.write(to: url("\(file).plist"))
        try openssl("cms", "-sign", "-nodetach", "-binary", "-outform", "DER", "-in", "\(file).plist",
                    "-signer", "ca.crt", "-inkey", "ca.key", "-out", "\(file).mobileprovision")
        return try Data(contentsOf: url("\(file).mobileprovision"))
    }

    /// A wildcard development profile for one leaf, and its p12.
    func makeIdentity(appID: String = "\(TestMaterial.team).*") throws -> (p12: Data, profile: Data) {
        let leaf = try makeLeaf("leaf")
        return (try makeP12("leaf"), try makeProfile(certificates: [leaf], appID: appID))
    }

    @discardableResult
    func openssl(_ arguments: String...) throws -> String {
        try run("/usr/bin/openssl", Array(arguments))
    }

    /// Runs a tool in the material folder; fails with its stderr.
    @discardableResult
    func run(_ tool: String, _ arguments: [String], input: Data? = nil) throws -> String {
        try Self.run(tool, arguments, in: directory, input: input)
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], in directory: URL, input: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        let errors = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: out, as: UTF8.self) + String(decoding: err, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ToolFailure(command: ([tool] + arguments).joined(separator: " "), output: text)
        }
        return text
    }

    struct ToolFailure: Error, CustomStringConvertible {
        let command: String
        let output: String
        var description: String { "\(command) failed:\n\(output)" }
    }

    // LibreSSL ignores -subj when the config has prompt = no, so leaf
    // requests use a config with an empty name section.
    private static let requestConfig = """
    [req]
    distinguished_name = dn

    [dn]

    """

    private static let config = """
    [req]
    distinguished_name = dn
    prompt = no

    [dn]
    CN = Eider Test CA
    O = Eider Tests

    [v3_ca]
    basicConstraints = critical,CA:TRUE
    keyUsage = critical,keyCertSign,cRLSign,digitalSignature
    subjectKeyIdentifier = hash

    [responder]
    basicConstraints = critical,CA:FALSE
    keyUsage = critical,digitalSignature
    extendedKeyUsage = OCSPSigning

    [leaf]
    basicConstraints = critical,CA:FALSE
    keyUsage = critical,digitalSignature
    extendedKeyUsage = critical,codeSigning
    authorityInfoAccess = OCSP;URI:http://127.0.0.1:9/ocsp
    subjectKeyIdentifier = hash
    authorityKeyIdentifier = keyid

    """
}
