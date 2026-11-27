import Foundation

/// The one error type `AppOperations` throws, so a caller handles one shape
/// whichever module the problem came from. `code` is stable (`install.encrypted`,
/// `download.hash_changed`, `catalog.fetch_failed`, `operations.not_installed`, ...);
/// `message` is a sentence a person can act on.
public struct OperationFailure: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    /// Maps what the other modules throw onto this type. Cancellation is not a
    /// failure and is never passed here.
    public static func wrap(_ error: Error) -> OperationFailure {
        switch error {
        case let failure as OperationFailure:
            return failure
        case let failure as InstallFailure:
            return OperationFailure(code: "install.\(failure.code.rawValue)", message: failure.message)
        case let failure as DownloadFailure:
            return OperationFailure(code: failure.code, message: failure.message)
        case let failure as CatalogFailure:
            return OperationFailure(code: failure.code, message: failure.message)
        case let failure as SourceListError:
            return OperationFailure(code: failure.code, message: failure.message)
        case let failure as UninstallFailure:
            return OperationFailure(code: "uninstall.failed", message: failure.message)
        default:
            return OperationFailure(code: "operations.unexpected", message: error.localizedDescription)
        }
    }

    static func notInstalled(_ bundleID: String) -> OperationFailure {
        OperationFailure(code: "operations.not_installed", message: "No installed app has the bundle id \(bundleID).")
    }

    static func notInCatalog(_ bundleID: String) -> OperationFailure {
        OperationFailure(
            code: "operations.not_in_catalog",
            message: "None of your sources lists \(bundleID). Add a source that does, or install from a file or an https address.")
    }

    /// How many candidates the message names; a tweak source lists 152 apps under one id.
    private static let ambiguousShown = 12

    /// One bundle id, several apps in the same source. The full entry id is the
    /// way to name one of them, so it is what each line ends with.
    static func ambiguousEntry(_ bundleID: String, candidates: [SourcedApp]) -> OperationFailure {
        let lines = candidates.prefix(ambiguousShown).map { entry in
            "  \(entry.app.name) \(entry.app.latest?.version ?? "-")  \(entry.id)"
        }
        let more = candidates.count > ambiguousShown ? ["  ... and \(candidates.count - ambiguousShown) more (eider search lists them)"] : []
        return OperationFailure(
            code: "operations.ambiguous_entry",
            message: "\(candidates.count) apps in one source share the bundle id \(bundleID). Name one by its full id:\n"
                + (lines + more).joined(separator: "\n"))
    }

    static func noSuchVersion(_ version: String, available: [String]) -> OperationFailure {
        OperationFailure(
            code: "operations.no_such_version",
            message: "The source has no version \(version). It offers: \(available.joined(separator: ", ")).")
    }

    static func badURL(_ url: URL) -> OperationFailure {
        OperationFailure(
            code: "operations.bad_url",
            message: "Eider only downloads over https (or http on this Mac), so it refused \(url.absoluteString).")
    }
}

extension OperationFailure: CodedFailure {
    public var failureCode: String { code }
    public var failureMessage: String { message }
}

extension InstallFailure: CodedFailure {
    public var failureCode: String { "install.\(code.rawValue)" }
    public var failureMessage: String { message }
}

extension UninstallFailure: CodedFailure {
    public var failureCode: String { "uninstall.failed" }
    public var failureMessage: String { message }
}
