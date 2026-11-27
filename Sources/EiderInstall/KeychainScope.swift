import Foundation
import Security

/// Which keychain `LocalRootAuthority` keeps its keys and certificates in.
///
/// The app uses `.default`: the data-protection keychain, items readable after the first
/// unlock and never migrated to another device. On macOS the tests use `.file(_:)` with a
/// throwaway keychain, because the data-protection keychain needs a signed binary with
/// keychain entitlements (unsigned `swift test` gets errSecMissingEntitlement) and the
/// owner's login keychain must never be touched.
public struct KeychainScope: @unchecked Sendable {
    /// Merged into SecItemAdd and SecKeyCreateRandomKey attributes.
    let addAttributes: [String: Any]
    /// Merged into SecItemCopyMatching and SecItemDelete queries.
    let queryAttributes: [String: Any]
    /// Merged into the attributes of a stored private key.
    let keyAttributes: [String: Any]

    public static let `default` = KeychainScope(
        addAttributes: [kSecUseDataProtectionKeychain as String: true],
        queryAttributes: [kSecUseDataProtectionKeychain as String: true],
        keyAttributes: [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly])

    #if os(macOS)
    /// A file-based keychain, for tests on the Mac.
    public static func file(_ keychain: SecKeychain) -> KeychainScope {
        KeychainScope(
            addAttributes: [kSecUseKeychain as String: keychain],
            queryAttributes: [kSecMatchSearchList as String: [keychain]],
            keyAttributes: [:])
    }
    #endif
}

/// Thin wrappers over SecItem calls; every query carries the scope's attributes.
struct KeychainStore {
    let scope: KeychainScope

    struct Failure: Error, CustomStringConvertible {
        let operation: String
        let status: OSStatus
        var description: String {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain \(operation) failed: \(message)"
        }
    }

    private func merged(_ base: [String: Any], _ extra: [String: Any]) -> CFDictionary {
        base.merging(extra) { current, _ in current } as CFDictionary
    }

    // MARK: Keys

    func privateKey(tag: String) throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(merged(query, scope.queryAttributes), &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result else { throw Failure(operation: "key lookup", status: status) }
        return (result as! SecKey)
    }

    /// A new P-256 key stored in the keychain. Its private half is used through SecKey only
    /// and is never exported.
    func createPrivateKey(tag: String, label: String) throws -> SecKey {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrLabel as String: label,
        ]
        privateAttributes.merge(scope.keyAttributes) { current, _ in current }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttributes,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(merged(attributes, scope.addAttributes), &error) else {
            let cfError = error?.takeRetainedValue()
            throw Failure(operation: "key creation (\(cfError.map { "\($0)" } ?? "unknown"))",
                          status: OSStatus(cfError.map { CFErrorGetCode($0) } ?? -1))
        }
        return key
    }

    func deleteKeys(tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
        ]
        try delete(query, what: "key")
    }

    // MARK: Certificates

    // A certificate is kept twice: as a certificate item, so that it pairs with its private key
    // into an identity, and as a generic-password item holding its DER under our label. The
    // second exists because the macOS file keychain ignores kSecAttrLabel when a certificate is
    // added and labels it with the subject's common name instead (measured 2026-11-28), so a
    // certificate item cannot be found again by a label of our own.

    private func derQuery(label: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: label,
            kSecAttrAccount as String: "certificate.der",
        ]
    }

    func certificate(label: String) throws -> SecCertificate? {
        var query = derQuery(label: label)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(merged(query, scope.queryAttributes), &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let der = result as? Data else {
            throw Failure(operation: "certificate lookup", status: status)
        }
        return SecCertificateCreateWithData(nil, der as CFData)
    }

    func store(certificate: SecCertificate, label: String) throws {
        try deleteCertificates(label: label)
        let certificateItem: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]
        let status = SecItemAdd(merged(certificateItem, scope.addAttributes), nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Failure(operation: "certificate add", status: status)
        }
        var derItem = derQuery(label: label)
        derItem[kSecValueData as String] = SecCertificateCopyData(certificate) as Data
        derItem.merge(scope.keyAttributes) { current, _ in current }
        let derStatus = SecItemAdd(merged(derItem, scope.addAttributes), nil)
        guard derStatus == errSecSuccess else {
            throw Failure(operation: "certificate record add", status: derStatus)
        }
    }

    func deleteCertificates(label: String) throws {
        guard let existing = try certificate(label: label) else { return }
        let der = SecCertificateCopyData(existing) as Data
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(merged(query, scope.queryAttributes), &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(operation: "certificate lookup", status: status)
        }
        for item in (result as? [SecCertificate]) ?? [] where SecCertificateCopyData(item) as Data == der {
            try delete([kSecClass as String: kSecClassCertificate, kSecValueRef as String: item],
                       what: "certificate")
        }
        try delete(derQuery(label: label), what: "certificate record")
    }

    /// The identity (certificate plus its private key) whose certificate is `certificate`.
    /// iOS has no SecIdentityCreateWithCertificate, so this lists identities and matches the DER.
    func identity(for certificate: SecCertificate) throws -> SecIdentity? {
        let wanted = SecCertificateCopyData(certificate) as Data
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(merged(query, scope.queryAttributes), &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
            throw Failure(operation: "identity lookup", status: status)
        }
        return identities.first { identity in
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return false }
            return SecCertificateCopyData(cert) as Data == wanted
        }
    }

    private func delete(_ query: [String: Any], what: String) throws {
        let status = SecItemDelete(merged(query, scope.queryAttributes))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(operation: "\(what) delete", status: status)
        }
    }
}
