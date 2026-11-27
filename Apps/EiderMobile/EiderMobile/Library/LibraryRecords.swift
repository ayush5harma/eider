import EiderCore
import Foundation

/// An IPA the person downloaded or imported, kept under `EiderPaths.ipas`.
/// What is known about it comes from the catalog entry it was downloaded from;
/// an imported file only has its name until it is installed once.
struct LibraryIPA: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    /// The file under `EiderPaths.ipas`; always `<id>.ipa`, never a name taken
    /// from a source or a shared file.
    let fileName: String
    var name: String
    var bundleID: String?
    var version: String?
    var build: String?
    var size: Int64
    let addedAt: Date
    /// The catalog entry it came from, carried into the installed record so
    /// Updates follows the same entry.
    var origin: InstallOrigin?
    var iconURL: URL?
    var sha256: String?

    struct Details: Sendable {
        var name: String
        var bundleID: String?
        var version: String?
        var build: String?
        var origin: InstallOrigin?
        var iconURL: URL?
        var sha256: String?
    }
}

/// An app Eider signed and installed on this device. Conforms to EiderCore's
/// `InstalledRecord`, so update matching is the Mac app's own rule.
struct InstalledApp: Codable, Identifiable, Hashable, Sendable, InstalledRecord {
    var id: String { bundleID }

    /// The id it was signed under, which the person may have changed.
    let bundleID: String
    let name: String
    let version: String
    let build: String
    let sourceURL: URL?
    let origin: InstallOrigin?
    let installedAt: Date
    let certificateID: UUID?
    let iconURL: URL?
}

/// What an unpacked app says about itself.
struct BundleInfo: Sendable {
    let bundleID: String
    let name: String
    let version: String
    let build: String

    static func read(appAt appURL: URL) throws -> BundleInfo {
        let data = try Data(contentsOf: appURL.appendingPathComponent("Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String
        else { throw LibraryError.unreadableApp }
        let build = plist["CFBundleVersion"] as? String ?? ""
        let name = plist["CFBundleDisplayName"] as? String ?? plist["CFBundleName"] as? String ?? appURL.deletingPathExtension().lastPathComponent
        return BundleInfo(
            bundleID: bundleID, name: DisplayText.sanitized(name),
            version: plist["CFBundleShortVersionString"] as? String ?? build, build: build)
    }
}

enum LibraryError: LocalizedError {
    case unreadableApp
    case notAnIPA
    case missingFile

    var errorDescription: String? {
        switch self {
        case .unreadableApp: "The app inside this IPA has no readable Info.plist."
        case .notAnIPA: "That file is not an IPA. Eider opens .ipa files only."
        case .missingFile: "The IPA is no longer in Eider's library. Download or import it again."
        }
    }
}
