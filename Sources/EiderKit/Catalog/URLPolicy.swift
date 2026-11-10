import Foundation

/// The one rule for every URL that comes from a source, a deep link or a
/// redirect: https; file only when the caller says the document itself was
/// local; http to this Mac only when the caller says so. Loopback is for a
/// source the user added by a loopback address and the items inside it, never
/// for an https source, a redirect from one, or an `eider://` link: those are
/// somebody else's words, and loopback reaches services on this Mac.
public enum URLPolicy {
    public static func isAllowed(_ url: URL, allowFile: Bool = false, allowLoopback: Bool = false) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return url.host?.isEmpty == false
        case "http":
            return allowLoopback && (url.host.map(isLoopback) ?? false)
        case "file":
            return allowFile
        default:
            return false
        }
    }

    /// Absolute URL for `raw`, relative to `base`, or nil when it is empty,
    /// malformed or not allowed.
    public static func resolve(_ raw: String, against base: URL?, allowFile: Bool, allowLoopback: Bool = false) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else {
            return nil
        }
        return isAllowed(url, allowFile: allowFile, allowLoopback: allowLoopback) ? url : nil
    }

    /// An http address on this Mac: the only kind of URL `allowLoopback` is about.
    public static func isLoopbackURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && (url.host.map(isLoopback) ?? false)
    }

    /// `localhost`, `::1` and the real 127.0.0.0/8 block. A prefix test let
    /// "127.evil.example.com" through, so the host is parsed as four decimal octets.
    static func isLoopback(_ host: String) -> Bool {
        let bare = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "localhost" || bare == "::1" { return true }
        let octets = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let values = octets.map { octet -> Int? in
            octet.count <= 3 && octet.allSatisfy { $0.isASCII && $0.isNumber } ? Int(octet) : nil
        }
        return values.allSatisfy { ($0 ?? 256) <= 255 } && values.first == 127
    }
}
