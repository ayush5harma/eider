import Darwin
import Foundation
import os

/// The manifest server: an HTTPS endpoint on another host that answers an itms-services
/// manifest built from its query, while the IPA itself still comes from this device.
///
/// Measured on an iPhone 17 Pro, iOS 27.3, 2026-11-28 (device syslog): appstored refuses a
/// manifest the iPhone serves itself, both from loopback and from its own Wi-Fi address
/// ("The manifest URL isn't external", ASDErrorDomain 850, shown as "Cannot connect to
/// <host>"). It accepts a manifest from another host whose asset URL points back at the
/// iPhone: a manifest served by the Mac at 192.168.1.117 naming
/// `https://192.168.1.50:<port>/<token>/app.ipa` installed and launched iTorrent.
///
/// The base URL carries a secret (`https://<host>/eider/manifest/<secret>.plist`), so the app
/// keeps it in the Keychain and shows it only masked. The full manifest URL is
/// `<base>?bundle=<id>&version=<v>&title=<t>&url=<ipa url>`, each value percent-encoded; the
/// server answers with the plist `InstallManifest.plist` describes.
public enum ManifestServer {
    public enum Invalid: Error, Equatable, CustomStringConvertible {
        case notAURL
        /// appstored only takes an https manifest URL.
        case notHTTPS
        case hasFragment
        /// The host is this iPhone (loopback or one of its own addresses), which appstored
        /// refuses as not external.
        case onThisDevice(String)

        public var description: String {
            switch self {
            case .notAURL: return "That is not a URL. Paste the manifest server's address, starting with https://."
            case .notHTTPS: return "The manifest server must be an https:// address: iOS only takes an HTTPS manifest."
            case .hasFragment: return "Remove the part after # from the manifest server's address."
            case .onThisDevice(let host):
                return "\(host) is this iPhone. iOS refuses a manifest served by the iPhone itself, so the manifest server has to run on another computer."
            }
        }
    }

    /// What a request to the manifest server got back.
    public enum Reachability: Sendable, Equatable {
        case reachable
        /// It answered, but not as a manifest server does (a wrong secret in the path, most
        /// likely, for a 404 or 403).
        case unexpectedStatus(Int)
        /// No answer: wrong host or port, the server is not running, or its certificate is not
        /// trusted on this device.
        case unreachable(String)
    }

    static let log = Logger(subsystem: "io.github.ayush5harma.EideriOS", category: "install")

    /// RFC 3986 unreserved characters. Spelled out because `CharacterSet.alphanumerics` also
    /// lets non-ASCII letters through unencoded.
    static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Parses and checks what the person pasted. `ownAddresses` is this device's interfaces.
    public static func validate(_ text: String,
                                ownAddresses: [LocalNetwork.InterfaceAddress] = LocalNetwork.interfaceAddresses())
        throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, let url = components.url else {
            throw Invalid.notAURL
        }
        guard scheme == "https" else { throw Invalid.notHTTPS }
        guard components.fragment == nil else { throw Invalid.hasFragment }
        if isThisDevice(host: host, ownAddresses: ownAddresses) { throw Invalid.onThisDevice(host) }
        return url
    }

    static func isThisDevice(host: String, ownAddresses: [LocalNetwork.InterfaceAddress]) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        guard let bytes = ipBytes(host) else { return false }
        return LocalNetwork.isOwnAddress(bytes, ownAddresses: ownAddresses)
    }

    /// The bytes of a literal IPv4 or IPv6 address, or nil for a name.
    static func ipBytes(_ host: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return withUnsafeBytes(of: v6) { Array($0) } }
        return nil
    }

    /// `<base>?bundle=..&version=..&title=..&url=..`, appended with `&` when the base already
    /// has a query.
    public static func manifestURL(base: URL, bundleID: String, version: String, title: String, ipa: URL) -> URL? {
        let pairs = [("bundle", bundleID), ("version", version), ("title", title), ("url", ipa.absoluteString)]
        var query: [String] = []
        for (name, value) in pairs {
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
            query.append("\(name)=\(encoded)")
        }
        let baseString = base.absoluteString
        let separator = base.query == nil ? (baseString.hasSuffix("?") ? "" : "?") : "&"
        return URL(string: baseString + separator + query.joined(separator: "&"))
    }

    /// The base for display: scheme, host and port, with the path (which holds the secret) and
    /// any query replaced by dots, keeping the last path component's extension.
    public static func masked(_ base: URL) -> String {
        var text = "\(base.scheme ?? "https")://\(base.host ?? "")"
        if let port = base.port { text += ":\(port)" }
        let path = base.path
        if !path.isEmpty, path != "/" {
            text += "/\u{2022}\u{2022}\u{2022}\u{2022}"
            if !base.pathExtension.isEmpty { text += ".\(base.pathExtension)" }
        }
        if base.query != nil { text += "?\u{2022}\u{2022}\u{2022}\u{2022}" }
        return text
    }

    /// The query `probe` sends: shaped like a real install's, for an app that does not exist,
    /// so a server that validates its query still answers 200 (or 400 if it is stricter).
    static func probeURL(base: URL) -> URL? {
        let ipa = URL(string: "https://192.168.0.1:1/\(String(repeating: "0", count: 32))/app.ipa")!
        return manifestURL(base: base, bundleID: "dev.eider.reachability-check", version: "1",
                           title: "Eider check", ipa: ipa)
    }

    /// Asks the manifest server for a manifest with the system's default trust, as appstored
    /// does. 200 and 400 count as reachable: a manifest server that refuses the made-up query
    /// is still there.
    public static func probe(_ base: URL, session: URLSession? = nil) async -> Reachability {
        guard let url = probeURL(base: base) else { return .unreachable("Could not build a request.") }
        let ownSession = session == nil
        let session = session ?? URLSession(configuration: .ephemeral)
        defer { if ownSession { session.finishTasksAndInvalidate() } }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        let host = base.host ?? "?"
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result = reachability(forStatus: status)
            log.info("manifest server \(host, privacy: .public) answered \(status, privacy: .public)")
            return result
        } catch {
            log.notice("manifest server \(host, privacy: .public) unreachable: \(error, privacy: .public)")
            return .unreachable(error.localizedDescription)
        }
    }

    static func reachability(forStatus status: Int) -> Reachability {
        status == 200 || status == 400 ? .reachable : .unexpectedStatus(status)
    }
}

/// The plist iOS fetches for an itms-services install: what the manifest server answers for
/// `bundle`, `version`, `title` and `url`.
enum InstallManifest {
    static func plist(ipa: URL, bundleID: String, version: String, title: String) throws -> Data {
        let manifest: [String: Any] = [
            "items": [[
                "assets": [[
                    "kind": "software-package",
                    "url": ipa.absoluteString,
                ]],
                "metadata": [
                    "bundle-identifier": bundleID,
                    "bundle-version": version,
                    "kind": "software",
                    "title": title,
                ],
            ] as [String: Any]],
        ]
        return try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0)
    }
}
