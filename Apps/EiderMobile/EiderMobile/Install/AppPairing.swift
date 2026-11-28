import Foundation

/// The pairing service the app uses. A placeholder until the `EiderPairing` library lands: the real
/// one wraps `PairingInstaller(pairingFile: RemotePairingFile(data:), host: "10.7.0.1", port: 49152)`
/// and replaces this file only.
struct AppPairing: PairingService {
    struct NotInBuild: LocalizedError {
        var errorDescription: String? { "Pairing install is not in this build yet." }
    }

    func validate(pairingFile: Data) throws -> String {
        throw NotInBuild()
    }

    func check(pairingFile: Data) async -> PairingReadiness {
        .refused(NotInBuild().localizedDescription)
    }

    func install(ipaAt: URL, bundleIdentifier: String, pairingFile: Data,
                 progress: @escaping @Sendable (PairingStage) -> Void) async throws {
        throw NotInBuild()
    }
}
