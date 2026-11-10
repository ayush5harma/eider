import Foundation

/// An Info.plist read and written through PropertyListSerialization, keeping
/// its on-disk format (binary stays binary).
struct InfoPlist {
    let url: URL
    private(set) var values: [String: Any]
    private let format: PropertyListSerialization.PropertyListFormat

    init(url: URL) throws {
        self.url = url
        var detected = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &detected) as? [String: Any]
        else { throw InstallFailure(.badBundle, "The app's Info.plist could not be read.") }
        values = plist
        format = detected
    }

    func string(_ key: String) -> String? {
        guard let value = values[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func integers(_ key: String) -> [Int]? { values[key] as? [Int] }

    mutating func set(_ key: String, _ value: Any) { values[key] = value }

    func write() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: format, options: 0)
        try data.write(to: url, options: .atomic)
    }
}

/// What the installer needs to know about the bundle before it changes anything.
struct BundleIdentity {
    let executable: String
    let bundleID: String
    /// What the IPA itself declares, before any override.
    let shippedID: String
    /// What the app shows as its name, cleaned.
    let displayName: String
    /// The installed bundle is named after this.
    let name: String
    let minimumOS: String?

    /// Reverse-DNS and nothing else: the id becomes a path (the container) and an
    /// IPA is untrusted, so "../../Documents" and "." are refused before use.
    static func isPlausibleBundleID(_ id: String) -> Bool { BundleIdentifier.isValid(id) }

    /// The executable is joined to the bundle path and handed to codesign, so it is a plain
    /// file name: no slash, no control, NUL or format character.
    static func isPlausibleExecutableName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= maxFileNameBytes && !name.contains("/") && name != "." && name != ".."
            && !DisplayText.containsUnsafe(name)
    }

    static let maxFileNameLength = 100
    private static let maxFileNameBytes = 255

    /// File-name safe: the installed bundle's path is built from it. Never empty,
    /// never hidden (a leading dot), never long.
    static func fileSafe(_ name: String) -> String {
        String(name.map { "/:\n\r".contains($0) ? "_" : $0 })
    }

    /// The name of the installed bundle, from what the app shows. Falls back to the
    /// bundle id when nothing usable is left.
    static func bundleFileName(shown: String, bundleID: String) -> String {
        func tidy(_ text: String) -> String {
            String(fileSafe(DisplayText.sanitized(text)).drop { $0 == "." }.prefix(maxFileNameLength))
                .trimmingCharacters(in: .whitespaces)
        }
        let name = tidy(shown)
        return name.isEmpty ? tidy(bundleID) : name
    }

    init(plist: InfoPlist, options: InstallOptions) throws {
        guard let executable = plist.string("CFBundleExecutable") else {
            throw InstallFailure(.badBundle, "The app's Info.plist has no CFBundleExecutable.")
        }
        guard let shippedID = plist.string("CFBundleIdentifier") else {
            throw InstallFailure(.badBundle, "The app's Info.plist has no CFBundleIdentifier.")
        }
        guard Self.isPlausibleBundleID(shippedID) else {
            throw InstallFailure(.unsafeName, "The app's bundle id (\(shippedID)) is not a plain reverse-DNS name, so it was not installed.")
        }
        guard Self.isPlausibleExecutableName(executable) else {
            throw InstallFailure(.unsafeName, "The app's executable name (\(executable)) is not a plain file name, so it was not installed.")
        }
        if let override = options.bundleID, !Self.isPlausibleBundleID(override) {
            throw InstallFailure(.invalidOption, "The bundle id \(override) is not a plain reverse-DNS name.")
        }
        // The first candidate with anything visible left wins; the bundle id is the last resort.
        let id = options.bundleID ?? shippedID
        let candidates = [options.displayName, plist.string("CFBundleDisplayName"), plist.string("CFBundleName"), executable]
        let shown = candidates.compactMap { $0 }.map(DisplayText.sanitized).first { !$0.isEmpty } ?? id
        self.executable = executable
        bundleID = id
        self.shippedID = shippedID
        displayName = shown
        name = Self.bundleFileName(shown: shown, bundleID: id)
        minimumOS = plist.string("MinimumOSVersion").map(DisplayText.sanitized).flatMap { $0.isEmpty ? nil : $0 }
    }
}
