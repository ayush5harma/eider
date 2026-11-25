import EiderKit
import SwiftUI

struct BrowseView: View {
    @Bindable var model: AppModel

    var body: some View {
        // HSplitView and VSplitView were tried first; their AppKit panes took
        // frames that cacheDisplay drew at half size, and a fixed list column is
        // what this screen wants anyway.
        HStack(spacing: 0) {
            list.frame(width: 320)
            Divider()
            Group {
                if let entry = model.selectedEntry {
                    AppDetailView(model: model, entry: entry)
                } else {
                    ContentUnavailableView("Select an app", systemImage: "app.dashed")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Browse")
        .searchable(text: $model.filter.text, prompt: "Search apps")
        .toolbar {
            ToolbarItem {
                Picker("Source", selection: $model.filter.source) {
                    Text("All Sources").tag(URL?.none)
                    ForEach(model.sources, id: \.url) { Text($0.name).tag(URL?.some($0.url)) }
                }
                .pickerStyle(.menu)
            }
        }
    }

    @ViewBuilder private var list: some View {
        if model.catalog.isEmpty {
            ContentUnavailableView {
                Label("No apps to browse", systemImage: "tray")
            } description: {
                Text("Add a source to see the apps it offers.")
            } actions: {
                Button("Go to Sources") { model.selection = .sources }
            }
        } else {
            // Read once: a body that read the property twice paid for it twice.
            let results = model.browseResults
            List(results, selection: $model.selectedAppID) { entry in
                BrowseRow(model: model, entry: entry).tag(entry.id)
            }
            .listStyle(.inset)
            .overlay {
                if results.isEmpty { ContentUnavailableView.search(text: model.filter.text) }
            }
        }
    }
}

private struct BrowseRow: View {
    let model: AppModel
    let entry: SourcedApp

    static let iconSide: CGFloat = 40

    var body: some View {
        HStack(spacing: 12) {
            // The icon is fetched only while the row is on screen, at most six
            // at a time, and cancelled when it scrolls away (RemoteImage).
            RemoteImage(
                url: entry.app.iconURL, sourceURL: entry.sourceURL,
                size: CGSize(width: Self.iconSide, height: Self.iconSide), corner: 9, fallback: entry.app.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.app.name).font(.body.weight(.medium)).lineLimit(1)
                Text(entry.app.developerName ?? entry.source.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            // Looked up here, so only the rows on screen ask.
            StatusTag(status: model.status(of: entry.app))
        }
        .padding(.vertical, 3)
    }
}

struct StatusTag: View {
    let status: InstallStatus

    var body: some View {
        switch status {
        case .notInstalled: EmptyView()
        case .installed: Pill(text: "Installed", systemImage: "checkmark")
        case .updateAvailable: UpdateBadge()
        }
    }
}
