import ArgumentParser
import EiderKit
import Foundation

private struct EventLine: Encodable {
    let type = "event"
    let step: InstallStep
    let message: String
    let fraction: Double
}

private struct ResultLine: Encodable {
    let type = "result"
    let app: InstalledApp
}

private struct ErrorLine: Encodable {
    let type = "error"
    let code: String
    let message: String
}

private func jsonLine<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return }
    print(text)
    fflush(stdout)
}

private func writeError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a decrypted .ipa as a Mac app."
    )

    @Argument(help: "The decrypted .ipa to install.")
    var ipa: String

    @Option(name: .customLong("dest"), help: "Install into this folder instead of /Applications.")
    var destination: String = "/Applications"

    @Flag(name: .customLong("mac-idiom"), help: "Render in the Mac idiom (1:1 with the display).")
    var macIdiom = false

    @Flag(name: .customLong("no-keychain"), help: "No emulated keychain: logins will not survive a relaunch.")
    var noKeychain = false

    @Option(name: .customLong("dylib"), help: "Also link this prebuilt .dylib into the app (repeatable).")
    var dylibs: [String] = []

    @Flag(help: "Replace a same-named app even if its bundle id differs.")
    var force = false

    @Flag(help: "Print one JSON object per event and a final result object.")
    var json = false

    func run() async throws {
        let options = InstallOptions(
            destination: URL(fileURLWithPath: destination, isDirectory: true),
            macIdiom: macIdiom,
            keychainShim: !noKeychain,
            extraDylibs: dylibs.map { URL(fileURLWithPath: $0) },
            force: force
        )
        let asJSON = json
        do {
            let app = try await Installer().install(ipa: URL(fileURLWithPath: ipa), options: options) { event in
                if asJSON {
                    jsonLine(EventLine(step: event.step, message: event.message, fraction: event.fraction))
                } else {
                    writeError(String(format: "[%3d%%] %@", Int(event.fraction * 100), event.message))
                }
            }
            if asJSON { jsonLine(ResultLine(app: app)) } else { print("Installed \(app.path.path)") }
        } catch let failure as InstallFailure {
            if asJSON { jsonLine(ErrorLine(code: failure.code.rawValue, message: failure.message)) } else {
                writeError("eider: \(failure.message) (\(failure.code.rawValue))")
            }
            throw ExitCode.failure
        }
    }
}

struct UninstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Move an installed app to the Trash and forget it."
    )

    @Argument(help: "The app's bundle id.")
    var bundleID: String

    @Flag(name: .customLong("remove-data"), help: "Also move the app's data container to the Trash.")
    var removeData = false

    func run() async throws {
        let uninstaller = Uninstaller(store: LibraryStore())
        do {
            try await uninstaller.uninstall(bundleID: bundleID, removeData: removeData)
            print("Removed \(bundleID)")
        } catch let failure as UninstallFailure {
            writeError("eider: \(failure.message)")
            throw ExitCode.failure
        }
    }
}
