import Foundation

/// An error that carries a stable code and a sentence a person can act on.
/// `OperationFailure.wrap` (EiderKit) maps the Mac engine's errors onto its
/// own type; code that lives in EiderCore and needs the same two strings, such
/// as the source list import, reads them through this instead, so it does not
/// have to know the Mac engine's error types.
public protocol CodedFailure: Error {
    var failureCode: String { get }
    var failureMessage: String { get }
}

extension CatalogFailure: CodedFailure {
    public var failureCode: String { code }
    public var failureMessage: String { message }
}

extension DownloadFailure: CodedFailure {
    public var failureCode: String { code }
    public var failureMessage: String { message }
}

extension SourceListError: CodedFailure {
    public var failureCode: String { code }
    public var failureMessage: String { message }
}

public extension Error {
    /// The code and message to show for any error: the error's own when it is a
    /// `CodedFailure`, otherwise the same fallback `OperationFailure.wrap` uses.
    var codedFailure: (code: String, message: String) {
        if let coded = self as? CodedFailure { return (coded.failureCode, coded.failureMessage) }
        return ("operations.unexpected", localizedDescription)
    }
}
