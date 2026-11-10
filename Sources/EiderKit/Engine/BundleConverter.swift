import Foundation

/// Walks an unpacked bundle and rewrites its Mach-O files for Mac Catalyst.
struct BundleConverter {
    let app: URL

    /// The first Swift overlay that is iOS-specific. /usr/lib/swift has no UIKit
    /// overlay on macOS; Catalyst's copy lives under /System/iOSSupport.
    static let iosSwiftUIKit = "@rpath/libswiftUIKit.dylib"
    static let catalystSwiftUIKit = "/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib"
    /// The legacy installer's PlayCover-derived floor: Catalyst minimum 11.0, SDK never below 14.0.
    static let minimumOS = MachOVersion(major: 11, minor: 0)
    static let sdkFloor = MachOVersion(major: 14, minor: 0)
    /// Names of tweak libraries that replace the keychain (AltStore/TrollStore-style fixes).
    static let keychainFixPattern = "keychain.?fix|sideload.?keychain"

    func relative(_ url: URL) -> String {
        let base = app.resolvingSymlinksInPath().path + "/"
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    // MARK: Enumerate

    /// Regular files under the bundle, sorted, with symlinks left alone.
    func regularFiles() -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: app, includingPropertiesForKeys: keys) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true, values?.isSymbolicLink != true { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    func machOFiles() -> [URL] { regularFiles().filter { MachOFiles.kind(of: $0) != .notMachO } }

    // MARK: Keychain-fix tweaks

    /// Replace each keychain-fix tweak library with the empty neutraliser under
    /// the tweak's own install name. The load command stays: removing it would
    /// shift the two-level-namespace ordinal of every later dylib. Returns the
    /// bundle-relative paths it replaced.
    func neutraliseKeychainFixes(with neutraliser: () throws -> URL) throws -> [String] {
        var replaced: [String] = []
        for file in regularFiles() where file.pathExtension.lowercased() == "dylib" {
            let name = relative(file)
            guard name.range(of: Self.keychainFixPattern, options: [.regularExpression, .caseInsensitive]) != nil,
                  let installName = try? MachOFiles.readImage(at: file).dylibID() else { continue }
            let permissions = try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
            let source = try neutraliser()
            try FileManager.default.removeItem(at: file)
            try FileManager.default.copyItem(at: source, to: file)
            if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
            do {
                try MachOFiles.edit(at: file) { try $0.setDylibID(installName) }
            } catch {
                throw InstallFailure(.machOEdit, "Could not neutralise \(name): \(error). The keychain shim would be defeated, so nothing was installed.")
            }
            replaced.append(name)
        }
        return replaced
    }

    // MARK: Encryption

    /// Bundle-relative paths of binaries still carrying FairPlay encryption.
    func encryptedBinaries(_ files: [URL]) -> [String] {
        files.filter { ((try? MachOFiles.readImage(at: $0).cryptID()) ?? 0) != 0 }.map(relative)
    }

    // MARK: Convert

    /// Thin to arm64, rewrite the platform to Mac Catalyst, repoint the one
    /// iOS-specific Swift overlay. Returns a warning when the overlay could not
    /// be repointed (the install goes on: the app may still launch).
    func convert(_ file: URL) throws -> String? {
        let name = relative(file)
        do {
            try MachOFiles.thinToArm64(at: file)
            let sdk = max(try MachOFiles.readImage(at: file).sdkVersion() ?? Self.sdkFloor, Self.sdkFloor)
            try MachOFiles.edit(at: file) { try $0.setPlatformMacCatalyst(minimumOS: Self.minimumOS, sdk: sdk) }
        } catch let error as MachOError {
            throw Self.failure(for: error, file: name)
        }
        do {
            try MachOFiles.edit(at: file) { try $0.changeLinkedDylib(from: Self.iosSwiftUIKit, to: Self.catalystSwiftUIKit) }
        } catch {
            return "Could not repoint libswiftUIKit in \(name) (\(error)); the app may fail to launch."
        }
        return nil
    }

    static func failure(for error: MachOError, file: String) -> InstallFailure {
        switch error {
        case .arm64eOnly:
            return InstallFailure(.noArm64Slice, "\(file) has only an arm64e slice, and Eider needs a plain arm64 one. Ask the source for an arm64 build.")
        case .noArm64Slice(let archs):
            return InstallFailure(.noArm64Slice, "\(file) has no arm64 slice (it has: \(archs.isEmpty ? "unknown" : archs.joined(separator: ", "))). It is not an Apple silicon build.")
        case .noRoom:
            return InstallFailure(.machOEdit, "\(file) has no spare room in its header for the change Eider needs to make: \(error).")
        default:
            return InstallFailure(.machOEdit, "\(file) could not be converted: \(error).")
        }
    }
}
