import EiderSign
import Foundation

/// The signer the app uses: EiderSign (zsign with OpenSSL). Building a
/// `SigningCertificate` opens the .p12 and checks it against the profile, so
/// the same call refuses a wrong password or a mismatched profile at Add time.
struct AppSigner: SigningService {
    func inspect(_ certificate: CertificateMaterial) async throws -> CertificateSummary {
        let signing = try Self.signingCertificate(certificate)
        return CertificateSummary(commonName: signing.commonName, certificateExpires: signing.certificateExpires)
    }

    /// Network-bound (Apple's OCSP responder); runs on the cooperative pool,
    /// never the main actor, since this struct is not actor-isolated.
    func revocationStatus(of certificate: CertificateMaterial) async -> RevocationState {
        guard let signing = try? Self.signingCertificate(certificate) else { return .unknown }
        switch await signing.revocationStatus() {
        case .good: return .valid
        case .revoked(let date): return .revoked(date)
        case .unknown(let reason): return .unavailable(reason)
        }
    }

    func sign(appAt appURL: URL, certificate: CertificateMaterial, options: SignOptions) async throws {
        let signing = try Self.signingCertificate(certificate)
        let signingOptions = SigningOptions(
            bundleIdentifier: options.bundleIdentifier, displayName: options.displayName, version: options.version,
            removeSupportedDevices: options.removeSupportedDevices, enableFileSharing: options.enableFileSharing,
            removeURLSchemes: options.removeURLSchemes)
        try await Signer.sign(appAt: appURL, certificate: signing, options: signingOptions)
    }

    private static func signingCertificate(_ material: CertificateMaterial) throws -> SigningCertificate {
        try SigningCertificate(p12: material.p12, password: material.password, provisioningProfile: material.provision)
    }
}
