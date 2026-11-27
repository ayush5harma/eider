import Foundation

/// Where an app installed from a source came from: the source's address, the
/// id the source lists the entry under, which since 0.1.2 may differ from
/// the id the IPA installed under ("com.kdt.l!vecontainer" installs as
/// "com.kdt.livecontainer"), and the name it lists it under: a tweak source
/// lists many different apps under one id, so the id alone does not say which.
/// Data only: the strings are compared with a catalog, never turned into a
/// path or a signing input (CatalogIdentifier).
public struct InstallOrigin: Codable, Sendable, Hashable {
    public let sourceURL: URL
    public let entryID: String
    /// The entry's name as listed. nil for an app installed by 0.1.4 to 0.1.6
    /// (the key is simply absent), whose entry may have been one of several
    /// under `entryID` (`UpdateChecker` then matches the installed app's name).
    public let entryName: String?

    public init(sourceURL: URL, entryID: String, entryName: String? = nil) {
        self.sourceURL = sourceURL
        self.entryID = entryID
        self.entryName = entryName
    }
}
