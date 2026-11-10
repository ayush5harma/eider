import Foundation

/// Turns a decrypted iOS `.ipa` into a Mac app on Apple silicon, with no Xcode
/// and no Command Line Tools: the only programs it runs are codesign, unzip
/// and lsregister. The steps, in the legacy installer's order: unpack,
/// validate, neutralise keychain-fix tweaks, refuse encrypted binaries,
/// convert every Mach-O, edit Info.plist, link the shims, sign, verify, place.
public struct Installer: Sendable {
    /// Cap on what an archive may unpack to (8 GB).
    public static let defaultMaxUncompressedBytes: UInt64 = IPAExtractor.defaultMaxUncompressedBytes

    private let shims: ShimLocator
    private let extractor: IPAExtractor
    private let store: LibraryStore

    public init(
        paths: EiderPaths = EiderPaths(),
        shims: ShimLocator = ShimLocator(),
        store: LibraryStore? = nil,
        maxUncompressedBytes: UInt64 = Installer.defaultMaxUncompressedBytes
    ) {
        self.shims = shims
        self.store = store ?? LibraryStore(paths: paths)
        extractor = IPAExtractor(maxUncompressedBytes: maxUncompressedBytes)
    }

    /// Install, record the app in the library, and return the record.
    /// Throws `InstallFailure` for anything about the IPA, the options or the
    /// environment that a person can act on.
    public func install(
        ipa: URL,
        options: InstallOptions = InstallOptions(),
        onEvent: @escaping @Sendable (InstallEvent) -> Void = { _ in }
    ) async throws -> InstalledApp {
        let run = InstallRun(ipa: ipa, options: options, shims: shims, extractor: extractor, onEvent: onEvent)
        let app: InstalledApp = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try run.execute()) } catch { continuation.resume(throwing: error) }
            }
        }
        do { try await store.record(app) } catch {
            // The app is installed; failing the call would misreport that.
            onEvent(InstallEvent(step: .warning, message: "Installed, but the library could not be updated: \(error.localizedDescription)", fraction: 0.99))
        }
        onEvent(InstallEvent(step: .done, message: "Installed \(app.path.path)", fraction: 1))
        return app
    }
}
