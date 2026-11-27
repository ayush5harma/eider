import EiderCore
import Foundation

/// One certificate the person added: a .p12, its password and a profile.
struct CertificateRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var nickname: String?
    let addedAt: Date
    let profile: ProvisioningProfile
    /// The certificate's subject name, as EiderSign read it from the .p12.
    let commonName: String
    let certificateExpires: Date

    var title: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return commonName
    }

    /// Signing stops at whichever runs out first, the certificate or the profile.
    var expires: Date { min(certificateExpires, profile.expires) }

    func expires(within interval: TimeInterval, now: Date = Date()) -> Bool {
        expires.timeIntervalSince(now) < interval
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
    private let signer: any SigningService

    init(paths: EiderPaths, signer: any SigningService) {
        self.paths = paths
        self.signer = signer
    }

    func index() throws -> CertificateIndex {
        try JSONFile.read(CertificateIndex.self, from: paths.certificateIndexFile) ?? CertificateIndex()
    }

    /// Nothing is stored until the signer has opened the .p12 with the password
    /// and found its certificate in the profile, so a wrong password or a
    /// mismatched profile is refused here rather than at the first install.
    /// The first certificate becomes the default.
    func add(p12: Data, provision: Data, password: String, nickname: String?) async throws -> CertificateRecord {
        let profile = try ProvisioningProfile.parse(provision)
        let summary = try await signer.inspect(CertificateMaterial(p12: p12, password: password, provision: provision))
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
            profile: profile, commonName: summary.commonName, certificateExpires: summary.certificateExpires)
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
}
