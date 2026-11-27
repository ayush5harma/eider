import Foundation

// The two seams between the app and the libraries that do the device work.
// EiderSign (signing) and EiderInstall (unpack, repack, local install) are
// being built separately; the app is written against these protocols so each
// lands by replacing one file: AppSigner.swift and AppInstaller.swift.

/// The three things a person adds for one certificate, as signing needs them.
/// Built from the stored files and the Keychain only for the length of one
/// install; never written anywhere.
struct CertificateMaterial: Sendable {
    let p12: Data
    let password: String
    let provision: Data
}

/// What the Install sheet lets a person change. nil keeps the app's own value.
/// Mirrors EiderSign's planned `SigningOptions`.
struct SignOptions: Sendable, Equatable {
    var bundleIdentifier: String?
    var displayName: String?
    var version: String?
    var removeSupportedDevices = false
    var enableFileSharing = false
    var removeURLSchemes = false
}

/// The OCSP answer for a certificate. `unknown` until a signer can ask.
enum RevocationState: Sendable, Equatable {
    case unknown
    case valid
    case revoked(Date?)
    case unavailable(String)
}

/// Signs an unpacked .app in place with the person's certificate.
protocol SigningService: Sendable {
    func revocationStatus(of certificate: CertificateMaterial) async -> RevocationState
    func sign(appAt appURL: URL, certificate: CertificateMaterial, options: SignOptions) async throws
}

/// Unpacks an IPA, packs a signed .app back into one, and installs it on this
/// device. `install` returns once iOS has taken the app, so the caller can
/// clean up the work directory afterwards.
protocol DeviceInstaller: Sendable {
    /// Unpacks into `directory` and returns the .app inside Payload.
    func unpack(ipaAt ipaURL: URL, into directory: URL) async throws -> URL
    func package(appAt appURL: URL, into ipaURL: URL) async throws
    func install(ipaAt ipaURL: URL, bundleIdentifier: String, version: String, title: String) async throws
}

/// What a placeholder throws, so the Install sheet says plainly why it stopped.
struct FeatureUnavailable: LocalizedError, Sendable {
    let feature: String

    var errorDescription: String? {
        "\(feature) is not available in this build of Eider yet."
    }
}
