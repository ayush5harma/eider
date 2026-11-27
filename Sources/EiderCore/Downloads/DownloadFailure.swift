import Foundation

public enum DownloadEvent: Sendable, Equatable {
    /// `expectedBytes` is the whole file, not what is left to fetch; nil when the server did not say.
    case started(expectedBytes: Int64?)
    /// `received` includes bytes kept from an earlier, interrupted attempt.
    case progress(received: Int64, expected: Int64?)
    case finished(file: URL, sha256: String)
}

/// Errors from the Downloads module. `code` is stable; `message` says what to do.
public enum DownloadFailure: Error, Equatable, LocalizedError, Sendable {
    case blockedURL(String)
    case sizeCapExceeded(limit: Int64)
    case httpStatus(Int)
    case incomplete(received: Int64, expected: Int64)
    case hashMismatch(expected: String, actual: String)
    case hashChanged(expected: String, actual: String)
    case hashRecordUnreadable(String)
    case alreadyInProgress(String)
    case network(String)
    case disk(String)

    public var code: String {
        switch self {
        case .blockedURL: return "download.blocked_url"
        case .sizeCapExceeded: return "download.too_large"
        case .httpStatus: return "download.http_status"
        case .incomplete: return "download.incomplete"
        case .hashMismatch: return "download.hash_mismatch"
        case .hashChanged: return "download.hash_changed"
        case .hashRecordUnreadable: return "download.hash_record_unreadable"
        case .alreadyInProgress: return "download.in_progress"
        case .network: return "download.network"
        case .disk: return "download.disk"
        }
    }

    public var message: String {
        switch self {
        case .blockedURL(let url):
            return "Eider only downloads over https (or http on this Mac), so it refused \(url)."
        case .sizeCapExceeded(let limit):
            return "The file is larger than the \(limit / 1_048_576) MB limit, so the download was stopped and discarded."
        case .httpStatus(let status):
            return "The server answered HTTP \(status) instead of sending the file. Check the source or try again later."
        case .incomplete(let received, let expected):
            return "The connection ended after \(received) of \(expected) bytes. Run the download again to resume it."
        case .hashMismatch(let expected, let actual):
            return "The file does not match the checksum the source published (expected \(expected), got \(actual)). It was deleted."
        case .hashChanged(let expected, let actual):
            return "This address served a different file than last time (was \(expected), now \(actual)). Download again with the changed-file override only if you trust the source."
        case .hashRecordUnreadable(let reason):
            return "Eider's record of past downloads could not be read (\(reason)). Move hashes.json aside to continue."
        case .alreadyInProgress(let file):
            return "\(file) is already being downloaded."
        case .network(let reason):
            return "The download failed: \(reason). Run it again to resume."
        case .disk(let reason):
            return "Eider could not write the download: \(reason)."
        }
    }

    public var errorDescription: String? { message }

    /// Maps what URLSession and the file system throw onto the stable errors.
    /// Returns nil for cancellation, which is not a failure.
    static func wrap(_ error: Error) -> DownloadFailure? {
        switch error {
        case let failure as DownloadFailure:
            return failure
        case is CancellationError:
            return nil
        case let url as URLError where url.code == .cancelled:
            return nil
        case TransferError.blockedRedirect(let target):
            return .blockedURL(target.absoluteString)
        case let cocoa as CocoaError where cocoa.isFileError:
            return .disk(cocoa.localizedDescription)
        default:
            return .network(error.localizedDescription)
        }
    }
}

extension CocoaError {
    fileprivate var isFileError: Bool {
        (CocoaError.fileNoSuchFile.rawValue...CocoaError.fileWriteVolumeReadOnly.rawValue).contains(code.rawValue)
    }
}
