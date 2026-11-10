import Foundation

/// Copies helper libraries into `Frameworks/` and adds a load command for each
/// to the main executable, because an interposing library only works when it
/// is loaded at launch.
struct ShimLinker {
    let app: URL
    let executable: URL

    var frameworks: URL { app.appendingPathComponent("Frameworks", isDirectory: true) }

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
