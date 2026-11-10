import Foundation

/// The install options sheet's fields as a form holds them (text boxes, not
/// optionals), turned into `InstallOptions` when the person confirms.
public struct InstallOptionsDraft: Equatable, Sendable {
    public var macIdiom = false
    public var keychainShim = true
    public var displayName = ""
    public var bundleID = ""
    public var removeExtensions = false
    public var resetData = false
    public var extraDylibs: [URL] = []
    public var destination: URL

    public init(destination: URL) {
        self.destination = destination
    }

    public func options() -> InstallOptions {
        InstallOptions(
            destination: destination, macIdiom: macIdiom, keychainShim: keychainShim,
            extraDylibs: extraDylibs, displayName: Self.trimmed(displayName),
            bundleID: Self.trimmed(bundleID), removeExtensions: removeExtensions, resetData: resetData)
    }

    private static func trimmed(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// An install waiting for the person to confirm its options.
public struct PendingInstall: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let request: InstallRequest
    public var draft: InstallOptionsDraft
}
