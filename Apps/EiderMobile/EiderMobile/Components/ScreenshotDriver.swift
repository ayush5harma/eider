#if DEBUG
import EiderCore
import Foundation

/// Debug builds only: opens a screen from the environment so screenshots can
/// be taken in a simulator without scripting taps (the Mac app's
/// SnapshotRunner plays the same part). `simctl launch` passes these as
/// SIMCTL_CHILD_EIDER_*:
///
///   EIDER_ADD_SOURCE  an https source to add first, through the normal add path
///   EIDER_SCREEN      browse, search, detail, install, library, updates,
///                     sources, certificates, add-certificate, settings
///   EIDER_APP         the app name for detail and install (default: the first)
///   EIDER_SEARCH      the search text for `search`
///
/// `install` downloads the app through DownloadManager like Get does, so pick
/// a small one.
@MainActor
enum ScreenshotDriver {
    static func run(_ model: MobileModel, environment: [String: String] = ProcessInfo.processInfo.environment) async {
        if let raw = environment["EIDER_ADD_SOURCE"], let url = URL(string: raw),
           !model.sources.contains(where: { $0.url == url }) {
            await model.addSource(url)
        }
        guard let screen = environment["EIDER_SCREEN"] else { return }
        // The index is built detached after the catalog loads.
        for _ in 0..<100 where model.browseResults.isEmpty && !model.catalog.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let entry = environment["EIDER_APP"].flatMap { name in
            model.browseResults.first { $0.app.name == name }
        } ?? model.browseResults.first

        switch screen {
        case "browse":
            model.tab = .browse
        case "search":
            model.tab = .browse
            model.filter.text = environment["EIDER_SEARCH"] ?? ""
        case "detail":
            model.tab = .browse
            if let entry { model.browsePath = [AppRoute(id: entry.id)] }
        case "install":
            model.tab = .browse
            if let entry {
                model.browsePath = [AppRoute(id: entry.id)]
                await model.get(entry)
            }
        case "library": model.tab = .library
        case "updates": model.tab = .updates
        case "sources": model.tab = .sources
        case "certificates": model.tab = .certificates
        case "add-certificate":
            model.tab = .certificates
            model.addingCertificate = true
        case "settings":
            model.showingSettings = true
        default:
            break
        }
    }
}
#endif
