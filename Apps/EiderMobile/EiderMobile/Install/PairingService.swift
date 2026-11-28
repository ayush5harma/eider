import Foundation

// The seam for the second install method, "Pairing (fully local)": the
// iPhone's own installation service reached through a loopback VPN with a
// RemotePairing pairing file, so no manifest server is involved. The views and
// InstallJob see only this protocol; AppPairing.swift holds the one
// implementation and is the single file to swap when the library lands.

/// Whether a pairing install can start right now.
enum PairingReadiness: Sendable, Equatable {
    case ready
    /// The loopback VPN is not up (the service at its address did not answer); the text says what was seen.
    case vpnOff(String)
    /// The service answered and refused the pairing file; the text is its reason.
    case refused(String)
}

/// How far one pairing install has got.
enum PairingStage: Equatable, Sendable {
    case connecting
    case uploading(sent: Int64, total: Int64)
    case installing(percent: Int)
    case finished
}

protocol PairingService: Sendable {
    /// Parses the pairing file and returns an identifier of the computer it was made on, to show
    /// the person; throws a message for them when the file is not a pairing file.
    func validate(pairingFile: Data) throws -> String
    /// Connects through the VPN and checks the pairing file is accepted, without installing.
    func check(pairingFile: Data) async -> PairingReadiness
    /// Uploads the signed IPA and installs it; returns once iOS has installed it.
    func install(ipaAt: URL, bundleIdentifier: String, pairingFile: Data,
                 progress: @escaping @Sendable (PairingStage) -> Void) async throws
}

/// The two ways to install on this device, as Settings offers them.
enum InstallMethod: String, CaseIterable, Identifiable, Sendable {
    case manifestServer
    case pairing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manifestServer: "Manifest server"
        case .pairing: "Pairing (fully local)"
        }
    }

    private static let defaultsKey = "installMethod"

    /// The stored choice; the manifest server until the person picks otherwise. A preference, not
    /// a secret, so UserDefaults.
    static var stored: InstallMethod {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(InstallMethod.init(rawValue:)) ?? .manifestServer
    }

    func store() {
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
    }
}

enum PairingHost {
    /// A host identifier long enough to be a UUID or a hash, shortened to its ends for display.
    static func shortened(_ identifier: String) -> String {
        guard identifier.count > 16 else { return identifier }
        return "\(identifier.prefix(8))\u{2026}\(identifier.suffix(4))"
    }
}
