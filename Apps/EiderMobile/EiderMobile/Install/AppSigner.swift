import Foundation

/// The signer the app uses. A placeholder until EiderSign lands: replace this
/// file's body with calls to `SigningCertificate(p12:password:provision:)`,
/// its `revocationStatus()` and `Signer.sign(appAt:certificate:options:)`,
/// mapping `SignOptions` onto `SigningOptions`. Nothing else changes.
struct AppSigner: SigningService {
    func revocationStatus(of certificate: CertificateMaterial) async -> RevocationState {
        .unknown
    }

    func sign(appAt appURL: URL, certificate: CertificateMaterial, options: SignOptions) async throws {
        throw FeatureUnavailable(feature: "Signing")
    }
}
