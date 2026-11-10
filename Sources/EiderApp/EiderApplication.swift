import AppKit
import EiderKit
import SwiftUI

/// One model for the whole process: the app delegate receives opened files and
/// links before any view exists, and must hand them to the same state the
/// window draws.
@MainActor
enum Shared {
    static let model = AppModel()
    static let snapshotDirectory = SnapshotRunner.directory(from: CommandLine.arguments)
}

@main
struct EiderApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Eider", id: "main") {
            RootView(model: Shared.model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1100, height: 720)
        .commands { EiderCommands(model: Shared.model) }

        Settings {
            SettingsView(model: Shared.model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let directory = Shared.snapshotDirectory else { return }
        // Deliberately no NSApp.activate: the run is for verification and must
        // not take the keyboard from whoever is working.
        Task { @MainActor in
            await SnapshotRunner(model: Shared.model, directory: directory).run()
        }
    }

    /// Double-clicked or dropped-on-Dock `.ipa` files and `eider://` links.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Shared.model.handleOpened(urls) }
    }
}

struct EiderCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Install IPA...") { chooseIPAFile(model) }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .sidebar) {
            Button("Refresh Sources") { Task { await model.refreshAllSources() } }
                .keyboardShortcut("r")
        }
        CommandGroup(after: .help) {
            Button("Check for Updates...") { Task { await model.checkForUpdates() } }
        }
    }
}

@MainActor
func chooseIPAFile(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "ipa")].compactMap { $0 }
    panel.allowsMultipleSelection = false
    panel.message = "Choose an .ipa file to install"
    if panel.runModal() == .OK { model.handleFiles(panel.urls) }
}
