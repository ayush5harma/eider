import Foundation

/// Errors from the Catalog module. `code` is stable; `message` says what to do.
public enum CatalogFailure: Error, Equatable, LocalizedError, Sendable {
    case notJSON
    case unrecognizedFormat
    case noUsableApps(warnings: [String])
    case blockedURL(String)
    case tooLarge(limit: Int64)
    case fetchFailed(String)
    case unknownSource(URL)
    case storeUnreadable(String)

    public var code: String {
        switch self {
        case .notJSON: return "catalog.not_json"
        case .unrecognizedFormat: return "catalog.unrecognized_format"
        case .noUsableApps: return "catalog.no_usable_apps"
        case .blockedURL: return "catalog.blocked_url"
        case .tooLarge: return "catalog.too_large"
        case .fetchFailed: return "catalog.fetch_failed"
        case .unknownSource: return "catalog.unknown_source"
        case .storeUnreadable: return "catalog.store_unreadable"
        }
    }

    public var message: String {
        switch self {
        case .notJSON:
            return "That address did not return JSON. Check that it points at the source file itself."
        case .unrecognizedFormat:
            return "The file is JSON but not an AltStore source or a PlayCover list. Check the address."
        case .noUsableApps(let warnings):
            let detail = warnings.first.map { " First problem: \($0)" } ?? ""
            return "The source lists no app Eider can install.\(detail)"
        case .blockedURL(let url):
            return "Eider only opens https addresses (and http on this Mac): \(url)"
        case .tooLarge(let limit):
            return "The response is larger than \(limit / 1_048_576) MB, so Eider refused it."
        case .fetchFailed(let reason):
            return "Could not fetch the source: \(reason)"
        case .unknownSource(let url):
            return "No source with the address \(url.absoluteString) has been added."
        case .storeUnreadable(let reason):
            return "The saved source list could not be read (\(reason)). Move sources.json aside and add the sources again."
        }
    }

    public var errorDescription: String? { message }
}
