import EiderKit
import SwiftUI

struct BrowseView: View {
    @Bindable var model: AppModel

    var body: some View {
        // HSplitView and VSplitView were tried first; their AppKit panes took
        // frames that cacheDisplay drew at half size, and a fixed list column is
        // what this screen wants anyway. The list stays a List (an NSTableView
        // underneath) because only that scrolls a 17,000-app catalog smoothly.
        HStack(spacing: 0) {
            list.frame(width: 340)
            Divider()
            Group {
                if let entry = model.selectedEntry {
                    AppDetailView(model: model, entry: entry)
                        .id(entry.id)
                } else {
                    ContentUnavailableView {
                        Label("Select an App", systemImage: "app.dashed")
                    } description: {
                        Text("Choose an app on the left to see its page.")
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Browse")
        .navigationSubtitle(subtitle)
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

    private var subtitle: String {
        let count = model.browseResults.count
        return count == 1 ? "1 app" : "\(count.formatted()) apps"
    }

    @ViewBuilder private var list: some View {
        if model.catalog.isEmpty {
            ContentUnavailableView {
                Label("No Apps to Browse", systemImage: "storefront")
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

/// The App Store's list row: icon, name, one quiet line, and where the app
/// stands on the right.
private struct BrowseRow: View {
    let model: AppModel
    let entry: SourcedApp

    static let iconSide: CGFloat = 46

    var body: some View {
        HStack(spacing: 12) {
            // The icon is fetched only while the row is on screen, at most six
            // at a time, and cancelled when it scrolls away (RemoteImage).
            CatalogIcon(url: entry.app.iconURL, sourceURL: entry.sourceURL, name: entry.app.name, side: Self.iconSide)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.app.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(entry.app.subtitle ?? entry.app.developerName ?? entry.source.name)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            // Looked up here, so only the rows on screen ask.
            StatusTag(status: model.status(of: entry.app))
        }
        .padding(.vertical, 5)
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
