import Foundation

/// Copies helper libraries into `Frameworks/` and adds a load command for each
/// to the main executable, because an interposing library only works when it
/// is loaded at launch.
struct ShimLinker {
    let app: URL
    let executable: URL

    var frameworks: URL { app.appendingPathComponent("Frameworks", isDirectory: true) }

    /// The shims an install links, in link order: the keychain shim unless
    /// opted out, one per system framework some binary in the bundle links
    /// (OpenGL ES, CallKit, AVFoundation: each shim corrects only that
    /// framework, so an app that does not link it gets nothing), and the
    /// app-group shim always. `linkedDylibs` is every dylib path any binary
    /// of the bundle links, which the legacy installer searched the same way
    /// (any binary, not just the main executable); a path is only compared
    /// to fixed framework names, never used to build a path. The quirks shim
    /// is linked last and only when `bundleID` (the installed app's) is
    /// exactly one it has a workaround for (`quirkBundleIDs`).
    static func shimsToLink(keychain: Bool, linkedDylibs: [String], bundleID: String = "") -> [(shim: Shim, label: String)] {
        func links(_ framework: String) -> Bool {
            linkedDylibs.contains { $0.contains("/\(framework).framework/") }
        }
        var wanted: [(shim: Shim, label: String)] = []
        if keychain { wanted.append((.keychain, "the keychain shim")) }
        if links("OpenGLES") { wanted.append((.gles, "the OpenGL ES shim")) }
        if links("CallKit") { wanted.append((.callKit, "the CallKit shim")) }
        if links("AVFoundation") { wanted.append((.camera, "the camera shim")) }
        wanted.append((.groups, "the app-group shim"))
        if quirkBundleIDs.contains(bundleID) { wanted.append((.quirks, "the app-quirks shim")) }
        return wanted
    }

    /// The apps Shims/ipa-quirks.m has a workaround for; keep the two in step.
    static let quirkBundleIDs: Set<String> = ["com.google.ios.youtube"]

    /// Install `source` as `Frameworks/<name>` and link it. Returns the copy,
    /// which the signing step must cover.
    func link(_ source: URL, as name: String, installName: String, label: String, convert: ((URL) throws -> Void)? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        let destination = frameworks.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        try convert?(destination)
        do {
            try MachOFiles.edit(at: executable) { try $0.addLoadDylib(installName) }
        } catch {
            throw InstallFailure(.machOEdit, "Could not link \(label) into \(executable.lastPathComponent): \(error).")
        }
        return destination
    }

    /// A prebuilt `--dylib`: named after its file (letters, digits, . _ -), converted like every other Mach-O.
    static func extraLibraryName(for source: URL) throws -> String {
        guard source.pathExtension == "dylib" else {
            throw InstallFailure(
                .unsupportedOption,
                "\(source.lastPathComponent) is not a prebuilt .dylib. Building C or Objective-C sources needs developer tools, which the installer does not use; build it for Mac Catalyst first."
            )
        }
        let base = source.deletingPathExtension().lastPathComponent
        guard !base.isEmpty, base.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }) else {
            throw InstallFailure(.invalidOption, "Use a library file name of letters, digits, '.', '_' and '-': \(base)")
        }
        return "lib\(base).dylib"
    }
}
