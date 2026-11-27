import Foundation

/// Installs a signed IPA on the device the app runs on, through an itms-services link served
/// from the app's own loopback HTTPS server. See docs/IOS.md, "Installing on the device itself".
public final class LocalInstaller {
    /// Unpacks `ipa`, calls `sign` on the `Payload/<name>.app` directory, and repacks it.
    ///
    /// Takes the signer as a closure so this module does not depend on how EiderSign signs.
    /// The returned IPA sits alone in a fresh work directory that the caller owns
    /// (remove it with `IPAArchive.removeWorkDirectory(url.deletingLastPathComponent())`).
    /// The unpacked copy is removed before this returns, on success and on failure.
    public static func prepareSignedIPA(from ipa: URL, sign: (URL) async throws -> Void) async throws -> URL {
        let unpackDirectory = try IPAArchive.makeWorkDirectory()
        defer { IPAArchive.removeWorkDirectory(unpackDirectory) }
        let app = try IPAArchive.unpack(ipa, into: unpackDirectory)
        try await sign(app)

        let outputDirectory = try IPAArchive.makeWorkDirectory()
        do {
            let output = outputDirectory.appendingPathComponent(
                app.deletingPathExtension().lastPathComponent + ".ipa")
            try IPAArchive.pack(appAt: app, to: output)
            return output
        } catch {
            IPAArchive.removeWorkDirectory(outputDirectory)
            throw error
        }
    }
}
