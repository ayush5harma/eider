import EiderCore
import Foundation
import Security

/// One certificate the person added: a .p12, its password and a profile.
struct CertificateRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var nickname: String?
    let addedAt: Date
    let profile: ProvisioningProfile
    /// The certificate's own name when the .p12 could be opened here.
    let commonName: String?
    /// False when iOS could not read the .p12 itself (some newer encodings);
    /// the password is then first checked when signing.
    let passwordChecked: Bool

    var title: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return commonName ?? profile.certificateNames.first ?? profile.name
    }

    func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        profile.expires.timeIntervalSince(now) < interval
    }
}

struct CertificateIndex: Codable, Sendable {
    var certificates: [CertificateRecord] = []
    var defaultID: UUID?
}

/// Files under `Certificates/<id>/`, the password in the Keychain, and a small
/// index (no secrets) beside them.
actor CertificateStore {
    private static let p12Name = "certificate.p12"
    private static let profileName = "profile.mobileprovision"

    private let paths: EiderPaths

    init(paths: EiderPaths) {
        self.paths = paths
    }

    func index() throws -> CertificateIndex {
        try JSONFile.read(CertificateIndex.self, from: paths.certificateIndexFile) ?? CertificateIndex()
    }

    /// Checks what can be checked on the device before anything is stored: the
    /// profile parses, the password opens the .p12, and the .p12's certificate
    /// is one the profile allows. The first certificate becomes the default.
    func add(p12: Data, provision: Data, password: String, nickname: String?) throws -> CertificateRecord {
        let profile = try ProvisioningProfile.parse(provision)
        let opened = try Self.open(p12, password: password, profile: profile)
        try paths.ensureMobile()

        let id = UUID()
        let directory = paths.certificates.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try p12.write(to: directory.appendingPathComponent(Self.p12Name), options: .completeFileProtectionUntilFirstUserAuthentication)
            try provision.write(to: directory.appendingPathComponent(Self.profileName), options: .completeFileProtectionUntilFirstUserAuthentication)
            try CertificateKeychain.setPassword(password, for: id)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            CertificateKeychain.deletePassword(for: id)
            throw error
        }

        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = CertificateRecord(
            id: id, nickname: trimmed?.isEmpty == false ? trimmed : nil, addedAt: Date(),
            profile: profile, commonName: opened.commonName, passwordChecked: opened.checked)
        var index = try index()
        index.certificates.append(record)
        if index.defaultID == nil { index.defaultID = id }
        try JSONFile.write(index, to: paths.certificateIndexFile)
        return record
    }

    func setDefault(_ id: UUID) throws {
        var index = try index()
        guard index.certificates.contains(where: { $0.id == id }) else { return }
        index.defaultID = id
        try JSONFile.write(index, to: paths.certificateIndexFile)
    }

    func remove(_ id: UUID) throws {
        var index = try index()
        index.certificates.removeAll { $0.id == id }
        if index.defaultID == id { index.defaultID = index.certificates.first?.id }
        try JSONFile.write(index, to: paths.certificateIndexFile)
        try? FileManager.default.removeItem(at: paths.certificates.appendingPathComponent(id.uuidString, isDirectory: true))
        CertificateKeychain.deletePassword(for: id)
    }

    /// The files and password for one signing run.
    func material(for id: UUID) throws -> CertificateMaterial {
        let directory = paths.certificates.appendingPathComponent(id.uuidString, isDirectory: true)
        guard let p12 = try? Data(contentsOf: directory.appendingPathComponent(Self.p12Name)),
              let provision = try? Data(contentsOf: directory.appendingPathComponent(Self.profileName))
        else { throw CertificateError.missingFiles }
        return CertificateMaterial(p12: p12, password: try CertificateKeychain.password(for: id), provision: provision)
    }

    // MARK: Checking a .p12

    private struct Opened {
        let commonName: String?
        let checked: Bool
    }

    /// SecPKCS12Import only reads the file on iOS; it adds nothing to the
    /// Keychain. A wrong password is refused outright. A file iOS cannot
    /// decode at all is let through unchecked, because zsign's OpenSSL reads
    /// encodings Security does not, and signing will say if it is bad.
    private static func open(_ p12: Data, password: String, profile: ProvisioningProfile) throws -> Opened {
        guard !p12.isEmpty else { throw CertificateError.unreadableCertificate }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(p12 as CFData, options, &items)
        switch status {
        case errSecSuccess:
            break
        case errSecAuthFailed:
            throw CertificateError.wrongPassword
        default:
            return Opened(commonName: nil, checked: false)
        }
        guard let first = (items as? [[String: Any]])?.first,
              let value = first[kSecImportItemIdentity as String],
              CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID()
        else { return Opened(commonName: nil, checked: false) }
        // The type id was checked just above, so the cast cannot fail.
        let identity = value as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
            return Opened(commonName: nil, checked: false)
        }
        let der = SecCertificateCopyData(certificate) as Data
        if !profile.allowedCertificates.isEmpty, !profile.allowedCertificates.contains(der) {
            throw CertificateError.notInProfile
        }
        return Opened(commonName: SecCertificateCopySubjectSummary(certificate) as String?, checked: true)
    }
}
