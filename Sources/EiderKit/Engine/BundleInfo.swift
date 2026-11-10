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
    /// The installed bundle is named after this.
    let name: String
    let minimumOS: String?

    /// Reverse-DNS and nothing else: the id becomes a path (the container) and an
    /// IPA is untrusted, so "../../Documents" and "." are refused before use.
    static func isPlausibleBundleID(_ id: String) -> Bool { BundleIdentifier.isValid(id) }

    static func isPlausibleExecutableName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".."
    }

    /// File-name safe: the installed bundle's path is built from it.
    static func fileSafe(_ name: String) -> String {
        String(name.map { "/:\n\r".contains($0) ? "_" : $0 })
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
        let shownName = options.displayName ?? plist.string("CFBundleDisplayName") ?? plist.string("CFBundleName") ?? executable
        let name = Self.fileSafe(shownName).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw InstallFailure(.invalidOption, "The display name is empty.") }
        self.executable = executable
        bundleID = options.bundleID ?? shippedID
        self.shippedID = shippedID
        self.name = name
        minimumOS = plist.string("MinimumOSVersion")
    }
}
