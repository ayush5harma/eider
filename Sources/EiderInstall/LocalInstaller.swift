import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What an install has reached. The stream ends after `.handedToIOS`: from then on the
/// install is iOS's (its progress shows on the home screen icon), not Eider's.
public enum InstallProgress: Sendable, Equatable {
    /// The install server is up; this is the manifest server's URL that names its IPA.
    case serving(manifest: URL)
    /// The itms-services link was handed to the system; iOS now asks the user to confirm.
    case opened(URL)
    /// iOS asked for the IPA, so it has the manifest.
    case manifestFetched
    case downloading(sent: Int64, total: Int64)
    /// iOS received every byte of the IPA.
    case handedToIOS
}

/// Keeps the app running in the background while iOS fetches from its server.
public struct BackgroundActivity: Sendable {
    /// Starts the activity and returns the closure that ends it.
    public let begin: @Sendable (_ name: String) async -> @Sendable () async -> Void

    public init(begin: @escaping @Sendable (_ name: String) async -> @Sendable () async -> Void) {
        self.begin = begin
    }

    public static let none = BackgroundActivity { _ in {} }

    #if canImport(UIKit)
    /// `UIApplication.beginBackgroundTask`: once iOS shows its install prompt the app may be
    /// suspended, and a suspended app cannot serve the IPA.
    public static let system = BackgroundActivity { name in
        let task = await BackgroundTask.begin(name: name)
        return { await task.end() }
    }
    #endif
}

#if canImport(UIKit)
@MainActor
private final class BackgroundTask {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    static func begin(name: String) -> BackgroundTask {
        let task = BackgroundTask()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { task.end() }
        }
        return task
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif

/// Installs a signed IPA on the device the app runs on, through an itms-services link whose
/// manifest comes from the manifest server on another host and whose IPA comes from the app's
/// own HTTPS server at its LAN address. See docs/IOS.md, "Installing on the device itself".
public final class LocalInstaller: @unchecked Sendable {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        /// The system would not open the link.
        case couldNotOpen(URL)
        /// The server stopped (timeout) before iOS had fetched the whole IPA.
        case timedOut
        case server(String)
        /// No Wi-Fi or other private-network address to serve from; appstored refuses loopback.
        case needsWiFi

        public var description: String {
            switch self {
            case .needsWiFi: return LocalNetwork.noAddressMessage
            case .couldNotOpen(let url): return "The system did not open \(url.absoluteString)."
            case .timedOut: return "iOS did not fetch the app before the install server timed out."
            case .server(let message): return "The install server failed: \(message)"
            }
        }
    }

    /// Opens a URL with the system: `UIApplication.open` on iOS; tests pass a stand-in.
    public typealias Opener = @Sendable (URL) async -> Bool

    public let authority: LocalRootAuthority
    private let opener: Opener
    private let background: BackgroundActivity
    private let timeout: TimeInterval
    private let grace: TimeInterval
    private let installAddress: @Sendable () -> DeviceAddress?

    /// - Parameters:
    ///   - opener: defaults to `UIApplication.shared.open` on iOS; elsewhere to one that fails.
    ///   - background: defaults to a UIKit background task on iOS.
    ///   - timeout: how long a server waits for iOS before it stops.
    ///   - grace: how long the server stays up after the IPA was fully served, in case iOS
    ///     comes back for another range.
    ///   - installAddress: the address to serve from, read at each install.
    public init(authority: LocalRootAuthority, opener: Opener? = nil, background: BackgroundActivity? = nil,
                timeout: TimeInterval = 15 * 60, grace: TimeInterval = 10,
                installAddress: @escaping @Sendable () -> DeviceAddress? = { LocalNetwork.installAddress() }) {
        self.authority = authority
        self.installAddress = installAddress
        #if canImport(UIKit)
        self.opener = opener ?? { await LocalInstaller.openWithSystem($0) }
        self.background = background ?? .system
        #else
        self.opener = opener ?? { _ in false }
        self.background = background ?? .none
        #endif
        self.timeout = timeout
        self.grace = grace
    }

    #if canImport(UIKit)
    @MainActor
    private static func openWithSystem(_ url: URL) async -> Bool {
        await UIApplication.shared.open(url)
    }
    #endif

    /// Serves `ipa`, opens an itms-services link to the manifest server's manifest for it,
    /// and reports progress until iOS has the whole IPA. Throws `.needsWiFi` without a
    /// private-network address, or if the server cannot start or the link cannot be opened.
    /// Cancelling the stream's consumer stops the server.
    ///
    /// - Parameter manifestBase: the manifest server's endpoint (`ManifestServer`). appstored
    ///   refuses a manifest the iPhone serves itself, loopback or Wi-Fi address ("The manifest
    ///   URL isn't external", iOS 27.3, 2026-11-28), but takes the IPA from the iPhone's Wi-Fi
    ///   address when a manifest from another host names it.
    public func install(ipa: URL, bundleID: String, version: String, title: String, manifestBase: URL)
        async throws -> AsyncThrowingStream<InstallProgress, Swift.Error> {
        guard let address = installAddress() else { throw Error.needsWiFi }
        let identity = try await authority.serverIdentity(for: [address])
        let server = try LocalInstallServer(identity: identity.identity, address: address, manifestBase: manifestBase,
                                            ipa: ipa, bundleID: bundleID, version: version, title: title,
                                            timeout: timeout)
        let manifest = try await server.start()
        guard let link = LocalInstallServer.itmsServicesURL(manifest: manifest) else {
            server.stop()
            throw Error.server("Could not build the itms-services link.")
        }

        let endBackground = await background.begin("Eider install")
        guard await opener(link) else {
            server.stop()
            await endBackground()
            throw Error.couldNotOpen(link)
        }

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: InstallProgress.self)
        continuation.yield(.serving(manifest: manifest))
        continuation.yield(.opened(link))
        continuation.onTermination = { termination in
            if case .cancelled = termination { server.stop() }
        }
        let grace = self.grace
        Task {
            var handed = false
            for await event in server.events {
                switch event {
                case .manifestFetched:
                    continuation.yield(.manifestFetched)
                case .ipaBytesServed(let sent, let total):
                    continuation.yield(.downloading(sent: sent, total: total))
                case .ipaFullyServed:
                    handed = true
                    continuation.yield(.handedToIOS)
                    continuation.finish()
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                        server.stop()
                    }
                case .failed(let message):
                    if !handed { continuation.finish(throwing: Error.server(message)) }
                    server.stop()
                case .stopped:
                    if !handed { continuation.finish(throwing: Error.timedOut) }
                }
            }
            await endBackground()
        }
        return stream
    }

    /// Serves the root's profile over plain HTTP on 127.0.0.1 and opens it (Safari, on iOS),
    /// which then offers to download it. The server stops shortly after the profile was fetched
    /// or after five minutes. Returns the profile URL.
    @discardableResult
    public func openProfileInstall() async throws -> URL {
        let server = LocalProfileServer(mobileconfig: try await authority.mobileconfig())
        let url = try await server.start()
        let endBackground = await background.begin("Eider profile")
        guard await opener(url) else {
            server.stop()
            await endBackground()
            throw Error.couldNotOpen(url)
        }
        let grace = self.grace
        Task {
            for await event in server.events where event == .profileFetched {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
                    server.stop()
                }
            }
            await endBackground()
        }
        return url
    }

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
