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
        /// "Terminating app due to uncaught exception": the app's own code (or a
        /// tweak injected into it) threw an Objective-C exception.
        case uncaughtException = "uncaught_exception"
        /// `open` itself refused, before any process existed.
        case openFailed = "open_failed"
        /// The app stayed running but its window is empty: its launch sequence
        /// presented its first screen before Catalyst's late first scene gave it
        /// a window ("... whose view is not in the window hierarchy") and never
        /// attached it. The process is left running.
        case windowNotAttached = "window_not_attached"
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
