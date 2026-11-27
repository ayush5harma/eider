import Foundation

extension MobileModel {
    /// Under this, an expiry shows red: a week is the time to get a new one.
    static let expiryWarning: TimeInterval = 7 * 24 * 3600

    func reloadCertificates() async {
        do {
            let index = try await certificateStore.index()
            certificates = index.certificates
            defaultCertificateID = index.defaultID
        } catch {
            report(error)
        }
        await checkRevocation()
    }

    func addCertificate(p12: Data, provision: Data, password: String, nickname: String?) async throws {
        _ = try await certificateStore.add(p12: p12, provision: provision, password: password, nickname: nickname)
        await reloadCertificates()
    }

    func makeDefault(_ certificate: CertificateRecord) async {
        do {
            try await certificateStore.setDefault(certificate.id)
        } catch {
            report(error)
        }
        await reloadCertificates()
    }

    func removeCertificate(_ certificate: CertificateRecord) async {
        do {
            try await certificateStore.remove(certificate.id)
            revocation[certificate.id] = nil
        } catch {
            report(error)
        }
        await reloadCertificates()
    }

    /// One OCSP question per certificate, through the signer; the placeholder
    /// answers `unknown` at once.
    private func checkRevocation() async {
        let signer = signer
        for certificate in certificates where revocation[certificate.id] == nil {
            guard let material = try? await certificateStore.material(for: certificate.id) else { continue }
            revocation[certificate.id] = await signer.revocationStatus(of: material)
        }
    }
}
