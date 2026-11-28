import EiderInstall
import Foundation

/// The installer the app uses: EiderInstall's IPA archive and its local
/// HTTPS server, trusted through Eider's own name-constrained root
/// (docs/IOS.md). One authority and one installer for the app's lifetime:
/// the model creates this once.
struct AppInstaller: DeviceInstaller {
    private let installer: LocalInstaller

    init() {
        installer = LocalInstaller(authority: LocalRootAuthority())
    }

    func unpack(ipaAt ipaURL: URL, into directory: URL) async throws -> URL {
        // Extraction is blocking file work; keep it off whichever actor called.
        try await Task.detached(priority: .userInitiated) {
            try InstallerFailure.wrapping { try IPAArchive.unpack(ipaURL, into: directory) }
        }.value
    }

    func package(appAt appURL: URL, into ipaURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try InstallerFailure.wrapping { try IPAArchive.pack(appAt: appURL, to: ipaURL) }
        }.value
    }

    /// The manifest server first, as the setup lists it. Its probe runs beside the local one.
    func readiness(manifestServer: URL?) async -> InstallReadiness {
        guard let manifestServer else { return .needsManifestServer }
        async let reachability = ManifestServer.probe(manifestServer)
        let local = await localReadiness()
        // Without Wi-Fi the manifest server on the network cannot answer either, and Wi-Fi is
        // the one thing to fix.
        if local == .needsWiFi { return .needsWiFi }
        guard await reachability == .reachable else { return .manifestServerUnreachable }
        return local
    }

    private func localReadiness() async -> InstallReadiness {
        switch await installer.authority.status() {
        case .notSetUp:
            (try? await installer.authority.hasOutdatedRoot()) == true ? .certificateOutdated : .notSetUp
        case .needsWiFi: .needsWiFi
        case .needsTrust: .needsTrust
        case .unreachable: .unreachable
        case .ready: .ready
        }
    }

    func openSetupProfile() async throws {
        do {
            try await installer.openProfileInstall()
        } catch {
            throw InstallerFailure(error)
        }
    }

    func install(ipaAt ipaURL: URL, bundleIdentifier: String, version: String, title: String, manifestServer: URL)
        async throws -> AsyncThrowingStream<InstallStage, Error> {
        let progress: AsyncThrowingStream<InstallProgress, Error>
        do {
            progress = try await installer.install(ipa: ipaURL, bundleID: bundleIdentifier, version: version, title: title,
                                                   manifestBase: manifestServer)
        } catch {
            throw InstallerFailure(error)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in progress {
                        switch event {
                        case .serving: continue
                        case .opened: continuation.yield(.opened)
                        case .manifestFetched: continuation.yield(.manifestFetched)
                        case .downloading(let sent, let total): continuation.yield(.downloading(sent: sent, total: total))
                        case .handedToIOS: continuation.yield(.handedToIOS)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: InstallerFailure(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension InstallReadiness {
    /// What to tell the person when there is no Wi-Fi, in EiderInstall's own words.
    static let wifiMessage = LocalNetwork.noAddressMessage
}

/// The manifest server's address, checked and shown by EiderInstall's rules
/// (`ManifestServer`), so the views need not import it.
enum ManifestServerAddress {
    /// Parses what the person pasted; throws a message for them when iOS would
    /// refuse it (not https, or this iPhone itself).
    static func parse(_ text: String) throws -> URL {
        try InstallerFailure.wrapping { try ManifestServer.validate(text) }
    }

    /// Scheme, host and port; the secret-bearing path masked.
    static func masked(_ url: URL) -> String {
        ManifestServer.masked(url)
    }
}

/// EiderInstall's errors describe themselves through `description`, not
/// `LocalizedError`; as they are, the sheet would only say "The operation
/// couldn't be completed". Converted here so no other file sees those types.
struct InstallerFailure: LocalizedError {
    let message: String

    init(_ error: Error) {
        switch error {
        case let failure as InstallerFailure: message = failure.message
        case let failure as LocalInstaller.Error: message = failure.description
        case let failure as IPAArchive.Error: message = failure.description
        case let failure as ManifestServer.Invalid: message = failure.description
        default: message = error.localizedDescription
        }
    }

    var errorDescription: String? { message }

    static func wrapping<Value>(_ body: () throws -> Value) throws -> Value {
        do {
            return try body()
        } catch {
            throw InstallerFailure(error)
        }
    }
}
