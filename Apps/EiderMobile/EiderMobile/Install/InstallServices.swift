import Foundation

// The two seams between the app and the libraries that do the device work:
// AppSigner.swift wraps EiderSign and AppInstaller.swift wraps EiderInstall.
// The rest of the app sees only these protocols and value types, so either
// library can change shape without touching a view.

/// The three things a person adds for one certificate, as signing needs them.
/// Built from the stored files and the Keychain only for the length of one
/// operation; never written anywhere.
struct CertificateMaterial: Sendable {
    let p12: Data
    let password: String
    let provision: Data
}

/// What the signer could verify about a certificate when it was added.
struct CertificateSummary: Sendable {
    let commonName: String
    let certificateExpires: Date
}

/// What the Install sheet lets a person change. nil keeps the app's own value.
struct SignOptions: Sendable, Equatable {
    var bundleIdentifier: String?
    var displayName: String?
    var version: String?
    var removeSupportedDevices = false
    var enableFileSharing = false
    var removeURLSchemes = false
}

/// The OCSP answer for a certificate.
enum RevocationState: Sendable, Equatable {
    case unknown
    case checking
    case valid
    case revoked(Date?)
    case unavailable(String)
}

/// Whether this device can install yet: a manifest server, and trust in Eider's local install
/// server.
enum InstallReadiness: Sendable, Equatable {
    /// No manifest server set. iOS refuses a manifest the iPhone serves itself ("The manifest
    /// URL isn't external"), so the manifest has to come from another computer.
    case needsManifestServer
    /// The manifest server is set but did not answer as one (no connection, or a status other
    /// than 200 or 400).
    case manifestServerUnreachable
    /// No root certificate made yet.
    case notSetUp
    /// The certificate on this device predates installs from the Wi-Fi address: it only covers
    /// 127.0.0.1, which iOS refuses for installs. The new one has to be installed and trusted.
    case certificateOutdated
    /// No Wi-Fi: iOS will not take an install served from the iPhone's internal address.
    case needsWiFi
    /// The root exists; its profile is not installed or not fully trusted.
    case needsTrust
    /// Eider could not connect to its own server at all; most likely Local Network access is off.
    case unreachable
    case ready
}

/// How far iOS has got with one install.
enum InstallStage: Sendable, Equatable {
    case opened
    case manifestFetched
    case downloading(sent: Int64, total: Int64)
    /// iOS has every byte; the rest is its install prompt and the Home Screen.
    case handedToIOS
}

/// Signs an unpacked .app in place with the person's certificate.
protocol SigningService: Sendable {
    /// Opens the .p12 with the password and checks it against the profile;
    /// throws a message for the person when it does not fit.
    func inspect(_ certificate: CertificateMaterial) async throws -> CertificateSummary
    func revocationStatus(of certificate: CertificateMaterial) async -> RevocationState
    func sign(appAt appURL: URL, certificate: CertificateMaterial, options: SignOptions) async throws
}

/// Unpacks an IPA, packs a signed .app back into one, and installs it on this
/// device through the local HTTPS server and an itms-services link.
protocol DeviceInstaller: Sendable {
    /// Unpacks into `directory` and returns the .app inside Payload.
    func unpack(ipaAt ipaURL: URL, into directory: URL) async throws -> URL
    func package(appAt appURL: URL, into ipaURL: URL) async throws
    /// `manifestServer` is the stored manifest server endpoint, nil when none is set.
    func readiness(manifestServer: URL?) async -> InstallReadiness
    /// Opens Eider's root certificate as a profile download in Safari.
    func openSetupProfile() async throws
    /// The stream ends after `.handedToIOS`; the server keeps the file open
    /// for a short grace period after that. The manifest comes from
    /// `manifestServer`, the IPA from this device.
    func install(ipaAt ipaURL: URL, bundleIdentifier: String, version: String, title: String, manifestServer: URL)
        async throws -> AsyncThrowingStream<InstallStage, Error>
}
