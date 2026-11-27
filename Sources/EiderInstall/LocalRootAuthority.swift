import CryptoKit
import Foundation
import Security
import SwiftASN1
import X509

/// Whether this device can install from the app's loopback HTTPS server.
public enum LocalInstallStatus: Sendable, Equatable {
    /// No root certificate yet; the first `rootCertificate()` or `mobileconfig()` creates it.
    case notSetUp
    /// The root exists, but iOS does not trust it: the profile is not installed, or full trust
    /// is not turned on in Settings > General > About > Certificate Trust Settings.
    case needsTrust
    /// An HTTPS request to the loopback server with the default system trust succeeded.
    case ready
}

/// The certificate and key the loopback HTTPS server presents.
public struct ServerIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    /// DER of the leaf certificate.
    public let leaf: Data
    /// DER of the root that issued it.
    public let root: Data
}

/// Eider's own root certificate authority on this device, and the server certificate it issues.
///
/// Proved on an iPhone 17 Pro with iOS 27.3 (2026-11-28): an itms-services install succeeds when
/// the manifest and IPA are served over HTTPS whose chain ends at a root the user installed as a
/// profile and fully trusted, even with that root name-constrained to loopback. The root's
/// private key stays in the keychain, and the critical name constraints (IP 127.0.0.1/32,
/// DNS localhost) mean that even a leaked key could not vouch for any other site.
public actor LocalRootAuthority {
    public static let leafCommonName = "Eider local server"
    public static let profileDisplayName = "Eider Local Install"

    /// iOS rejects TLS server certificates valid for more than 825 days from a user-trusted root;
    /// 300 days stays well under that and re-issue is automatic.
    static let leafLifetime: TimeInterval = 300 * 86_400
    static let leafRenewalWindow: TimeInterval = 30 * 86_400
    static let rootLifetime: TimeInterval = 10 * 365 * 86_400
    /// Covers a device clock a little behind the one that issued the certificate.
    static let backdate: TimeInterval = 3_600

    private let store: KeychainStore
    private let namespace: String
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - namespace: prefix of every keychain tag and label, so tests can keep their own items.
    ///   - keychain: where keys and certificates live (`.default` in the app).
    public init(namespace: String = "dev.eider.install", keychain: KeychainScope = .default) {
        self.init(namespace: namespace, keychain: keychain, now: { Date() })
    }

    init(namespace: String, keychain: KeychainScope, now: @escaping @Sendable () -> Date) {
        self.store = KeychainStore(scope: keychain)
        self.namespace = namespace
        self.now = now
    }

    private var rootKeyTag: String { namespace + ".root.key" }
    private var rootLabel: String { namespace + ".root" }
    private var leafKeyTag: String { namespace + ".leaf.key" }
    private var leafLabel: String { namespace + ".leaf" }

    // MARK: Root

    /// Whether a root certificate and its key exist, without creating them.
    public func hasRoot() throws -> Bool {
        try existingRoot() != nil
    }

    /// DER of the root certificate, created on first use.
    public func rootCertificate() throws -> Data {
        try ensureRoot().der
    }

    /// An unsigned configuration profile that installs the root certificate.
    /// Its identifiers derive from the root, so downloading it again replaces the same profile.
    public func mobileconfig() throws -> Data {
        try MobileConfig.rootProfile(certificate: ensureRoot().der, displayName: Self.profileDisplayName)
    }

    /// Removes the root, the server certificate and both keys. The next use starts over, and
    /// the user has to install and trust the new profile.
    public func reset() throws {
        try store.deleteCertificates(label: leafLabel)
        try store.deleteKeys(tag: leafKeyTag)
        try store.deleteCertificates(label: rootLabel)
        try store.deleteKeys(tag: rootKeyTag)
    }

    private struct Root {
        let key: SecKey
        let certificate: Certificate
        let der: Data
    }

    private func existingRoot() throws -> Root? {
        guard let key = try store.privateKey(tag: rootKeyTag),
              let secCertificate = try store.certificate(label: rootLabel) else { return nil }
        let der = SecCertificateCopyData(secCertificate) as Data
        let certificate = try Certificate(derEncoded: Array(der))
        // A root whose key was replaced underneath it is unusable; start over.
        guard certificate.publicKey == (try Certificate.PrivateKey(key)).publicKey else { return nil }
        return Root(key: key, certificate: certificate, der: der)
    }

    private func ensureRoot() throws -> Root {
        if let root = try existingRoot(), root.certificate.notValidAfter > now() { return root }
        try reset()

        let key = try store.createPrivateKey(tag: rootKeyTag, label: Self.profileDisplayName + " root key")
        let signingKey = try Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName("\(Self.profileDisplayName) (\(Self.randomHex(bytes: 4)))")
            OrganizationName("Eider")
        }
        let issued = now()
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
            Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            Critical(NameConstraints(
                permittedDNSDomains: ["localhost"],
                permittedIPRanges: [ASN1OctetString(contentBytes: [127, 0, 0, 1, 255, 255, 255, 255])]))
            SubjectKeyIdentifier(hash: signingKey.publicKey)
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: signingKey.publicKey,
            notValidBefore: issued - Self.backdate,
            notValidAfter: issued + Self.rootLifetime,
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: signingKey)
        let der = try Self.der(certificate)
        try store.store(certificate: try Self.secCertificate(der), label: rootLabel)
        return Root(key: key, certificate: certificate, der: der)
    }

    // MARK: Server certificate

    /// The identity for the loopback HTTPS server: a leaf issued by the root, re-issued when it
    /// has less than 30 days left or when the root changed.
    public func serverIdentity() throws -> ServerIdentity {
        let root = try ensureRoot()
        let key = try store.privateKey(tag: leafKeyTag)
            ?? store.createPrivateKey(tag: leafKeyTag, label: Self.leafCommonName + " key")
        let publicKey = try Certificate.PrivateKey(key).publicKey

        var leaf = try store.certificate(label: leafLabel)
        if let current = leaf, !isUsable(current, root: root, publicKey: publicKey) { leaf = nil }
        if leaf == nil {
            let certificate = try issueLeaf(publicKey: publicKey, root: root)
            try store.store(certificate: certificate, label: leafLabel)
            leaf = certificate
        }
        guard let leaf, let identity = try store.identity(for: leaf) else {
            throw KeychainStore.Failure(operation: "server identity", status: errSecItemNotFound)
        }
        return ServerIdentity(identity: identity, leaf: SecCertificateCopyData(leaf) as Data, root: root.der)
    }

    private func isUsable(_ secCertificate: SecCertificate, root: Root, publicKey: Certificate.PublicKey) -> Bool {
        guard let leaf = try? Certificate(derEncoded: Array(SecCertificateCopyData(secCertificate) as Data)) else {
            return false
        }
        return leaf.publicKey == publicKey
            && leaf.issuer == root.certificate.subject
            && root.certificate.publicKey.isValidSignature(leaf.signature, for: leaf)
            && leaf.notValidAfter.timeIntervalSince(now()) > Self.leafRenewalWindow
    }

    private func issueLeaf(publicKey: Certificate.PublicKey, root: Root) throws -> SecCertificate {
        let issued = now()
        let rootKeyIdentifier = try root.certificate.extensions.subjectKeyIdentifier?.keyIdentifier
        let extensions = try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            // The names go only in subjectAltName: OpenSSL reads a host-like subject CN as a DNS
            // name and then fails the name constraints ("permitted subtree violation"), measured
            // while proving the method on 2026-11-28.
            SubjectAlternativeNames([
                .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1])),
                .dnsName("localhost"),
            ])
            SubjectKeyIdentifier(hash: publicKey)
            if let rootKeyIdentifier {
                AuthorityKeyIdentifier(keyIdentifier: rootKeyIdentifier)
            }
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: issued - Self.backdate,
            notValidAfter: issued + Self.leafLifetime,
            issuer: root.certificate.subject,
            subject: try DistinguishedName { CommonName(Self.leafCommonName) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: try Certificate.PrivateKey(root.key))
        return try Self.secCertificate(try Self.der(certificate))
    }

    // MARK: Helpers

    static func der(_ certificate: Certificate) throws -> Data {
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return Data(serializer.serializedBytes)
    }

    static func secCertificate(_ der: Data) throws -> SecCertificate {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw KeychainStore.Failure(operation: "certificate decode", status: errSecDecode)
        }
        return certificate
    }

    static func randomHex(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            bytes = (0..<count).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Configuration profiles for the root certificate.
enum MobileConfig {
    static func rootProfile(certificate der: Data, displayName: String) throws -> Data {
        // Stable identifiers from the certificate's hash: the same root always yields the same
        // profile, and a new root a new one.
        let digest = sha256(der)
        let payloadUUID = uuid(from: digest, salt: 0x01)
        let profileUUID = uuid(from: digest, salt: 0x02)
        let suffix = String(profileUUID.prefix(8)).lowercased()
        let profile: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "dev.eider.install.profile.\(suffix)",
            "PayloadUUID": profileUUID,
            "PayloadDisplayName": displayName,
            "PayloadDescription": "Lets Eider install apps from its own server on this device. "
                + "The certificate is limited to 127.0.0.1 and localhost.",
            "PayloadOrganization": "Eider",
            "PayloadContent": [[
                "PayloadType": "com.apple.security.root",
                "PayloadVersion": 1,
                "PayloadIdentifier": "dev.eider.install.root.\(suffix)",
                "PayloadUUID": payloadUUID,
                "PayloadDisplayName": displayName,
                "PayloadCertificateFileName": "EiderLocalInstall.cer",
                "PayloadContent": der,
            ] as [String: Any]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }

    private static func sha256(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }

    private static func uuid(from digest: [UInt8], salt: UInt8) -> String {
        var bytes = Array(digest.prefix(16))
        bytes[0] ^= salt
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // name-based version
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return uuid.uuidString
    }
}
