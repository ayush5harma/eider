/// Changes made to the app before it is signed. Everything is off by default.
public struct SigningOptions: Sendable, Hashable {
    /// Replaces the app's bundle identifier. In nested apps and extensions the
    /// old identifier is replaced wherever it appears (com.old.widget ->
    /// com.new.widget), which is zsign's rule.
    public var bundleIdentifier: String?
    /// Sets CFBundleDisplayName and CFBundleName.
    public var displayName: String?
    /// Sets CFBundleVersion and CFBundleShortVersionString.
    public var version: String?
    /// Removes UISupportedDevices, which limits an app to listed device models.
    public var removeSupportedDevices: Bool
    /// Sets UIFileSharingEnabled and UISupportsDocumentBrowser, so the app's
    /// Documents folder shows in the Files app.
    public var enableFileSharing: Bool
    /// Removes CFBundleURLTypes, so the app claims no URL schemes.
    public var removeURLSchemes: Bool

    public init(
        bundleIdentifier: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        removeSupportedDevices: Bool = false,
        enableFileSharing: Bool = false,
        removeURLSchemes: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.version = version
        self.removeSupportedDevices = removeSupportedDevices
        self.enableFileSharing = enableFileSharing
        self.removeURLSchemes = removeURLSchemes
    }
}
