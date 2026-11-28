import Foundation
import Security

/// Serves one IPA over HTTPS at one of this device's own LAN addresses, answering only
/// connections from the device itself, and names it in a manifest URL on the manifest server.
///
/// The manifest is not served here: appstored refuses a manifest the iPhone serves itself,
/// from 127.0.0.1 and from its own Wi-Fi address alike ("The manifest URL isn't external",
/// iOS 27.3, measured 2026-11-28; see `ManifestServer`), but it fetches the IPA from the
/// iPhone's Wi-Fi address once a manifest from another host points there. The one path,
/// `/<token>/app.ipa`, carries a random 128-bit token, so another app on the device that finds
/// the port still cannot fetch the IPA. Everything else is a 404. The server stops itself
/// after `timeout`.
public final class LocalInstallServer: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// iOS asked for the IPA (HEAD or GET), so it has the manifest from the manifest server.
        case manifestFetched
        /// Distinct bytes of the IPA sent so far, and its size.
        case ipaBytesServed(sent: Int64, total: Int64)
        /// Every byte of the IPA went out at least once, in one GET or in ranges.
        case ipaFullyServed
        case failed(String)
        /// The server stopped (by `stop()` or the timeout); no further events follow.
        case stopped
    }

    public let events: AsyncStream<Event>
    public let token: String
    public let ipa: URL
    public let bundleID: String
    public let version: String
    public let title: String
    /// The address the IPA URL names and the listener binds.
    public let address: DeviceAddress
    /// The manifest server's endpoint (`ManifestServer`).
    public let manifestBase: URL

    private let continuation: AsyncStream<Event>.Continuation
    private let timeout: TimeInterval
    private let identity: SecIdentity
    private let ownAddresses: @Sendable () -> [LocalNetwork.InterfaceAddress]
    private let ipaSize: Int64
    private let lock = NSLock()
    private var server: LocalHTTPServer?
    private var ipaRequested = false
    private var served = ServedRanges()
    private var fullyServed = false
    private var stopped = false
    private var port: UInt16?

    /// - Parameters:
    ///   - identity: a leaf whose subjectAltName holds `address`
    ///     (`LocalRootAuthority.serverIdentity(for:)`).
    ///   - address: this device's LAN address (`LocalNetwork.installAddress()`).
    ///   - manifestBase: the manifest server's endpoint, on another host.
    public convenience init(identity: SecIdentity, address: DeviceAddress, manifestBase: URL, ipa: URL,
                            bundleID: String, version: String, title: String,
                            timeout: TimeInterval = 15 * 60) throws {
        try self.init(identity: identity, address: address, manifestBase: manifestBase,
                      ownAddresses: { LocalNetwork.interfaceAddresses() },
                      ipa: ipa, bundleID: bundleID, version: version, title: title, timeout: timeout)
    }

    /// `ownAddresses` decides which remote addresses count as this device; tests narrow it.
    init(identity: SecIdentity, address: DeviceAddress, manifestBase: URL,
         ownAddresses: @escaping @Sendable () -> [LocalNetwork.InterfaceAddress], ipa: URL, bundleID: String,
         version: String, title: String, timeout: TimeInterval) throws {
        self.identity = identity
        self.address = address
        self.manifestBase = manifestBase
        self.ownAddresses = ownAddresses
        self.ipa = ipa
        self.bundleID = bundleID
        self.version = version
        self.title = title
        self.timeout = timeout
        self.token = LocalRootAuthority.randomHex(bytes: 16)
        let attributes = try FileManager.default.attributesOfItem(atPath: ipa.path)
        self.ipaSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    deinit { stop() }

    /// The manifest server's URL for this install, naming `ipaURL` as the asset.
    public var manifestURL: URL? {
        ipaURL.flatMap {
            ManifestServer.manifestURL(base: manifestBase, bundleID: bundleID, version: version, title: title, ipa: $0)
        }
    }

    /// `https://<address>:<port>/<token>/app.ipa`, once started.
    public var ipaURL: URL? {
        guard let port = lock.withLock({ port }) else { return nil }
        return URL(string: "https://\(address):\(port)\(ipaPath)")
    }

    private var ipaPath: String { "/\(token)/app.ipa" }

    /// `itms-services://?action=download-manifest&url=<percent-encoded manifest URL>`.
    public var itmsServicesURL: URL? {
        manifestURL.flatMap(Self.itmsServicesURL(manifest:))
    }

    public static func itmsServicesURL(manifest: URL) -> URL? {
        guard let encoded = manifest.absoluteString.addingPercentEncoding(
            withAllowedCharacters: ManifestServer.unreserved) else {
            return nil
        }
        return URL(string: "itms-services://?action=download-manifest&url=" + encoded)
    }

    /// Starts listening and returns the manifest server's URL for this install.
    @discardableResult
    public func start() async throws -> URL {
        let server = LocalHTTPServer(identity: identity, binding: .address(address), ownAddresses: ownAddresses) {
            [weak self] request in self?.route(request)
        }
        server.onBodySent = { [weak self] path, range in self?.bodySent(path: path, range: range) }
        server.onResponse = { [weak self] request, status in self?.responded(request, status: status) }
        server.onFailure = { [weak self] error in self?.continuation.yield(.failed("\(error)")) }
        let port = try await server.start()
        let alreadyStopped = lock.withLock {
            self.server = stopped ? nil : server
            self.port = port
            return stopped
        }
        if alreadyStopped {
            server.stop()
            throw LocalHTTPServer.ServerError(description: "The server was stopped while starting.")
        }
        guard let manifestURL else {
            stop()
            throw LocalHTTPServer.ServerError(description: "Could not build the manifest URL from the manifest server's address.")
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop() }
        return manifestURL
    }

    public func stop() {
        let (first, server): (Bool, LocalHTTPServer?) = lock.withLock {
            defer { stopped = true; self.server = nil }
            return (!stopped, self.server)
        }
        guard first else { return }
        server?.stop()
        continuation.yield(.stopped)
        continuation.finish()
    }

    private func route(_ request: HTTPRequest) -> HTTPResource? {
        guard request.path == ipaPath else { return nil }
        return HTTPResource(body: .file(ipa), contentType: "application/octet-stream", size: ipaSize)
    }

    private func responded(_ request: HTTPRequest, status: Int) {
        guard request.path == ipaPath, (200..<300).contains(status) else { return }
        let first = lock.withLock {
            defer { ipaRequested = true }
            return !ipaRequested
        }
        if first { continuation.yield(.manifestFetched) }
    }

    private func bodySent(path: String, range: Range<Int64>) {
        guard path == ipaPath else { return }
        let (sent, becameFull): (Int64, Bool) = lock.withLock {
            served.insert(range)
            let full = !fullyServed && served.covers(size: ipaSize)
            if full { fullyServed = true }
            return (served.total, full)
        }
        continuation.yield(.ipaBytesServed(sent: sent, total: ipaSize))
        if becameFull { continuation.yield(.ipaFullyServed) }
    }
}

/// Serves the root's configuration profile over plain HTTP on 127.0.0.1.
///
/// Plain HTTP because Safari has to fetch the profile before the root is trusted. Only
/// `/root.mobileconfig` answers; it carries nothing secret (a public certificate).
public final class LocalProfileServer: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        case profileFetched
        case stopped
    }

    public static let path = "/root.mobileconfig"

    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let mobileconfig: Data
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var server: LocalHTTPServer?
    private var stopped = false

    public init(mobileconfig: Data, timeout: TimeInterval = 5 * 60) {
        self.mobileconfig = mobileconfig
        self.timeout = timeout
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    deinit { stop() }

    /// Starts listening and returns `http://127.0.0.1:<port>/root.mobileconfig`.
    @discardableResult
    public func start() async throws -> URL {
        let profile = mobileconfig
        let server = LocalHTTPServer(identity: nil) { request in
            request.path == Self.path ? .data(profile, contentType: "application/x-apple-aspen-config") : nil
        }
        server.onResponse = { [weak self] request, status in
            if request.method == "GET", status == 200 { self?.continuation.yield(.profileFetched) }
        }
        let port = try await server.start()
        let alreadyStopped = lock.withLock {
            self.server = stopped ? nil : server
            return stopped
        }
        if alreadyStopped {
            server.stop()
            throw LocalHTTPServer.ServerError(description: "The server was stopped while starting.")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in self?.stop() }
        return URL(string: "http://127.0.0.1:\(port)\(Self.path)")!
    }

    public func stop() {
        let (first, server): (Bool, LocalHTTPServer?) = lock.withLock {
            defer { stopped = true; self.server = nil }
            return (!stopped, self.server)
        }
        guard first else { return }
        server?.stop()
        continuation.yield(.stopped)
        continuation.finish()
    }
}
