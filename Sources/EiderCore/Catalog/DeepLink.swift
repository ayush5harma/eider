import Foundation

/// `eider://source/<url>` adds a source; `eider://install/<url>` starts an
/// install. The inner URL gets the same policy as any URL in a source, except
/// that file URLs are never accepted: a link in a web page must not be able to
/// point the app at a file on this Mac.
public enum DeepLink: Equatable, Sendable {
    case addSource(URL)
    case install(URL)

    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "eider", let host = url.host?.lowercased() else { return nil }
        guard let inner = innerURL(of: url, host: host) else { return nil }
        switch host {
        case "source": return .addSource(inner)
        case "install": return .install(inner)
        default: return nil
        }
    }

    /// Everything after `eider://<host>/`, taken from the raw string so that the
    /// inner query and fragment stay with the inner URL.
    private static func innerURL(of url: URL, host: String) -> URL? {
        let text = url.absoluteString
        guard let range = text.range(of: "://\(host)/", options: .caseInsensitive) else { return nil }
        var rest = String(text[range.upperBound...])
        if !rest.contains("://"), let decoded = rest.removingPercentEncoding { rest = decoded }
        guard let inner = URL(string: rest), URLPolicy.isAllowed(inner) else { return nil }
        return inner
    }
}
