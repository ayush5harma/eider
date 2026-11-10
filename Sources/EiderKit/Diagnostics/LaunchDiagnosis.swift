import Foundation

/// Why an installed app did not stay running. `code` is stable (scripts and the
/// app match on it); `summary` is one sentence a person can act on; `evidence`
/// holds the log or crash-report lines it was concluded from.
public struct LaunchDiagnosis: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable, CaseIterable {
        /// macOS "System Policy:" denial (a protected folder, usually an app-group container).
        case systemPolicy = "system_policy"
        /// The app's own sandbox ("Sandbox:" in com.apple.sandbox.reporting) refused an operation.
        case sandboxDenial = "sandbox_denial"
        /// Keychain error -34018: no keychain access group entitlement.
        case keychainEntitlement = "keychain_entitlement"
        /// dyld "Library not loaded".
        case libraryNotLoaded = "library_not_loaded"
        /// dyld "Symbol not found".
        case symbolNotFound = "symbol_not_found"
        case invalidSignature = "invalid_signature"
        /// FairPlay-encrypted binary.
        case encryptedBinary = "encrypted_binary"
        /// `open` itself refused, before any process existed.
        case openFailed = "open_failed"
        case unknown
    }

    public let code: Code
    public let summary: String
    public let evidence: [String]

    public init(code: Code, summary: String, evidence: [String] = []) {
        self.code = code
        self.summary = summary
        self.evidence = evidence
    }
}

/// What `LaunchProbe.launch` found.
public enum LaunchResult: Sendable, Equatable {
    case running(pid: Int32)
    case failed(LaunchDiagnosis)
}
