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
            List(model.browseResults, selection: $model.selectedAppID) { entry in
                BrowseRow(entry: entry, status: model.status(of: entry.app)).tag(entry.id)
            }
            .overlay {
                if model.browseResults.isEmpty { ContentUnavailableView.search(text: model.filter.text) }
            }
        }
    }
}

private struct BrowseRow: View {
    let entry: SourcedApp
    let status: InstallStatus

    var body: some View {
        HStack {
            // Icons load only in the detail pane: listing must not contact every
            // source's image host just because the section was opened.
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 36, height: 36)
                .overlay(Text(String(entry.app.name.prefix(1))).font(.headline).foregroundStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(entry.app.name).lineLimit(1)
                Text(entry.app.developerName ?? entry.source.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            StatusTag(status: status)
        }
    }
}

struct StatusTag: View {
    let status: InstallStatus

    var body: some View {
        switch status {
        case .notInstalled: EmptyView()
        case .installed: Text("Installed").font(.caption).foregroundStyle(.secondary)
        case .updateAvailable: UpdateBadge()
        }
    }
}
