import Foundation

/// The app's own preferences. A file under `EiderPaths.home` rather than
/// UserDefaults, so `EIDER_HOME` moves every byte of state together and the
/// tests and the smoke script never touch the owner's preferences.
public struct AppSettings: Codable, Equatable, Sendable {
    public var defaultInstallLocation: URL

    public init(defaultInstallLocation: URL = InstallOptions.defaultDestination) {
        self.defaultInstallLocation = defaultInstallLocation
    }

    public static func file(in paths: EiderPaths) -> URL {
        paths.home.appendingPathComponent("settings.json")
    }

    /// A missing or unreadable file is the defaults: a settings file must never
    /// stop the app from opening.
    public static func load(from paths: EiderPaths) -> AppSettings {
        guard let data = try? Data(contentsOf: file(in: paths)),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return settings
    }

    public func save(to paths: EiderPaths) throws {
        try paths.ensure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.file(in: paths), options: .atomic)
    }
}
