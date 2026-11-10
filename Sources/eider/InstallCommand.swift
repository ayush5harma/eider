import ArgumentParser
import EiderKit
import Foundation

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install an app from a decrypted .ipa, an https address or a source, as a Mac app."
    )

    @Argument(help: "A .ipa file, an https address of one, or the bundle id of an app in your sources.")
    var target: String

    @Option(help: "Install this version (bundle id installs only; default is the newest).")
    var version: String?

    @Option(name: .customLong("dest"), help: "Install into this folder instead of /Applications.")
    var destination: String = "/Applications"

    @Flag(name: .customLong("mac-idiom"), help: "Render in the Mac idiom (1:1 with the display).")
    var macIdiom = false

    @Flag(name: .customLong("no-keychain"), help: "No emulated keychain: logins will not survive a relaunch.")
    var noKeychain = false

    @Option(name: .customLong("dylib"), help: "Also link this prebuilt .dylib into the app (repeatable).")
    var dylibs: [String] = []

    @Option(name: .customLong("name"), help: "Install under this name instead of the app's own.")
    var displayName: String?

    @Option(name: .customLong("bundle-id"), help: "Install under this bundle id instead of the app's own.")
    var bundleID: String?

    @Flag(name: .customLong("remove-extensions"), help: "Drop app extensions (a common reason an app fails to sign or open).")
    var removeExtensions = false

    @Flag(name: .customLong("reset"), help: "Clear the app's saved data first (the app must be quit).")
    var reset = false

    @Flag(help: "Replace a same-named app even if its bundle id differs.")
    var force = false

    @OptionGroup var common: CommonOptions

    private struct Payload: Encodable { let app: InstalledApp }

    /// What `target` names.
    enum Source: Equatable {
        case localFile(URL)
        case address(URL)
        case catalog(String)
    }

    func validate() throws {
        guard version != nil else { return }
        if case .catalog = Self.resolve(target) { return }
        throw ValidationError("--version only applies when installing by bundle id.")
    }

    func run() async throws {
        try await common.guarded { output in
            let operations = AppOperations()
            let options = makeOptions()
            let onEvent = output.progressHandler()
            let app: InstalledApp
            switch Self.resolve(target) {
            case .localFile(let file):
                app = try await operations.install(localIPA: file, options: options, onEvent: onEvent)
            case .address(let url):
                app = try await operations.install(ipaURL: url, options: options, onEvent: onEvent)
            case .catalog(let id):
                guard let entry = try await operations.catalogEntry(bundleID: id) else {
                    throw OperationFailure.notInCatalogForCLI(id)
                }
                let release = try version.map { try AppOperations.version($0, of: entry.app) }
                app = try await operations.install(app: entry.app, version: release, from: entry.source, options: options, onEvent: onEvent)
            }
            output.result(Payload(app: app), text: "Installed \(app.path.path)")
        }
    }

    func makeOptions() -> InstallOptions {
        InstallOptions(
            destination: URL(fileURLWithPath: (destination as NSString).expandingTildeInPath, isDirectory: true),
            macIdiom: macIdiom,
            keychainShim: !noKeychain,
            extraDylibs: dylibs.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            displayName: displayName,
            bundleID: bundleID,
            removeExtensions: removeExtensions,
            resetData: reset,
            force: force
        )
    }

    /// An existing file wins; then an address (or an `eider://install/` link);
    /// anything that looks like a path but is not there is a missing file, not a
    /// bundle id; the rest is a bundle id.
    static func resolve(_ text: String) -> Source {
        let expanded = (text as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) { return .localFile(URL(fileURLWithPath: expanded)) }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased() {
            if scheme == "eider", case .install(let inner)? = DeepLink.parse(url) { return .address(inner) }
            if scheme == "https" || scheme == "http" || scheme == "file" { return .address(url) }
        }
        if text.contains("/") || text.lowercased().hasSuffix(".ipa") { return .localFile(URL(fileURLWithPath: expanded)) }
        return .catalog(text)
    }
}

extension OperationFailure {
    fileprivate static func notInCatalogForCLI(_ bundleID: String) -> OperationFailure {
        OperationFailure(
            code: "operations.not_in_catalog",
            message: "None of your sources lists \(bundleID), and no file or address has that name. Add a source with: eider source add <url>")
    }
}
