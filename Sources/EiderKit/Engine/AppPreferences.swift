import Foundation

/// Writes the interface-size keys (`InterfaceScale`) into an installed app's
/// own preferences, `<containers>/<bundle id>/Data/Library/Preferences/<bundle id>`,
/// through cfprefsd (as `DataReset` clears them), so a running copy's cache
/// does not bring old values back. The app reads them at its next launch.
/// Writing before the first launch is fine: containermanagerd adopts the
/// `Data` folder it finds (measured 2026-11-27, macOS 27.3).
public struct AppPreferences: Sendable {
    static let scaleKey = "iOSMacScaleFactor"
    static let macIdiomKey = "UIUserInterfaceIdiomMac"

    let containersDirectory: URL

    public static let standard = AppPreferences(containersDirectory: DataReset.standard.containersDirectory)

    init(containersDirectory: URL) {
        self.containersDirectory = containersDirectory
    }

    /// Applies `scale` (nothing at all for nil, the setting of an app installed
    /// before 0.1.9) and returns a line saying what the app will do.
    @discardableResult
    func apply(_ scale: InterfaceScale?, bundleID: String, display: DisplayMetrics?) throws -> String? {
        guard let scale else { return nil }
        guard BundleIdentifier.isValid(bundleID) else {
            throw InstallFailure(.invalidOption, "\(bundleID) is not a bundle id, so its preferences were not changed.")
        }
        let factor = scale.factor(on: display)
        try write([
            Self.scaleKey: factor.map { NSNumber(value: $0) },
            Self.macIdiomKey: scale == .macIdiom ? kCFBooleanTrue : nil,
        ], bundleID: bundleID)
        return Self.describe(scale, factor: factor, display: display)
    }

    /// The factor recorded in the app's preferences (nil: UIKit's default).
    func storedFactor(bundleID: String) -> Double? {
        guard BundleIdentifier.isValid(bundleID) else { return nil }
        return (CFPreferencesCopyValue(Self.scaleKey as CFString, domain(bundleID), kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.doubleValue
    }

    func storedMacIdiom(bundleID: String) -> Bool {
        guard BundleIdentifier.isValid(bundleID) else { return false }
        return (CFPreferencesCopyValue(Self.macIdiomKey as CFString, domain(bundleID), kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool) ?? false
    }

    static func describe(_ scale: InterfaceScale, factor: Double?, display: DisplayMetrics?) -> String {
        switch scale {
        case .macIdiom: return "Interface size: Mac idiom (1:1)"
        case .ipad: return "Interface size: 77% (UIKit's iPad default)"
        case .auto:
            let percent = Int(((factor ?? 1) * 100).rounded())
            return "Interface size: Auto, \(percent)%" + (display.map { " for the \($0.summary)" } ?? "")
        default: return "Interface size: \(scale.label)"
        }
    }

    // MARK: cfprefsd

    private func domain(_ bundleID: String) -> CFString {
        plist(bundleID).deletingPathExtension().path as CFString
    }

    func plist(_ bundleID: String) -> URL {
        containersDirectory.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data/Library/Preferences/\(bundleID).plist")
    }

    /// Sets each key, or removes it where the value is nil, then flushes.
    /// cfprefsd declines some locations without an error (a folder under
    /// /var/folders, measured 2026-11-27) and the values then live only in this
    /// process's cache, so success is judged by the file on disk.
    private func write(_ values: [String: CFPropertyList?], bundleID: String) throws {
        let domain = domain(bundleID)
        for (key, value) in values {
            CFPreferencesSetValue(key as CFString, value ?? nil, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        }
        let flushed = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let wroteKey = values.values.contains { $0 != nil }
        guard flushed, !wroteKey || FileManager.default.fileExists(atPath: plist(bundleID).path) else {
            throw InstallFailure(.placementFailed, "Could not save the interface size into \(plist(bundleID).path).")
        }
    }
}
