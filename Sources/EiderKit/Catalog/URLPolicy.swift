import Foundation

/// The one rule for every URL that comes from a source, a deep link or a
/// redirect: https; http only to this Mac; file only when the caller says the
/// document itself was local.
public enum URLPolicy {
    public static func isAllowed(_ url: URL, allowFile: Bool = false) -> Bool {
        switch url.scheme?.lowercased() {
        case "https":
            return url.host?.isEmpty == false
        case "http":
            return url.host.map(isLoopback) ?? false
        case "file":
            return allowFile
        default:
            return false
        }
    }

    /// Absolute URL for `raw`, relative to `base`, or nil when it is empty,
    /// malformed or not allowed.
    public static func resolve(_ raw: String, against base: URL?, allowFile: Bool) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else {
            return nil
        }
        return isAllowed(url, allowFile: allowFile) ? url : nil
    }

    private static func isLoopback(_ host: String) -> Bool {
        let bare = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return bare == "localhost" || bare == "::1" || bare == "127.0.0.1"
            || (bare.hasPrefix("127.") && bare.split(separator: ".").count == 4)
    }
}
