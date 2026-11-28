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
        checkRevocation()
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

    /// One OCSP question per certificate per session, all at once and not
    /// awaited: a responder that takes its full 15 s timeout must not hold up
    /// launch. The signer's call runs off the main actor; only the answer
    /// lands here.
    private func checkRevocation() {
        let store = certificateStore
        let signer = signer
        for certificate in certificates where revocation[certificate.id] == nil {
            let id = certificate.id
            revocation[id] = .checking
            Task { [weak self] in
                let state: RevocationState
                if let material = try? await store.material(for: id) {
                    state = await signer.revocationStatus(of: material)
                } else {
                    state = .unavailable(CertificateError.missingFiles.localizedDescription)
                }
                self?.revocation[id] = state
            }
        }
    }

    /// Asks the manifest server and probes the local server with the system's
    /// own trust (EiderInstall); only `.ready` lets an install start.
    func checkInstallReadiness() async {
        isCheckingReadiness = true
        defer { isCheckingReadiness = false }
        installReadiness = await installer.readiness(manifestServer: manifestServer)
    }

    /// Checks and stores what the person entered as the manifest server, then
    /// checks readiness again. Returns the message to show when it is refused.
    func saveManifestServer(_ text: String) async -> String? {
        do {
            let url = try ManifestServerAddress.parse(text)
            try ManifestServerKeychain.set(url)
            manifestServer = url
        } catch {
            return error.localizedDescription
        }
        await checkInstallReadiness()
        return nil
    }

    func clearManifestServer() async {
        ManifestServerKeychain.delete()
        manifestServer = nil
        await checkInstallReadiness()
    }

    /// Serves Eider's root as a profile and opens it in Safari, which offers to
    /// download it; the person then installs and trusts it in Settings.
    func openInstallSetupProfile() async {
        do {
            try await installer.openSetupProfile()
        } catch {
            report(error)
        }
        await checkInstallReadiness()
    }
}
