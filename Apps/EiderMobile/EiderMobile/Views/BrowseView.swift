import EiderCore
import SwiftUI

/// A pushed app page, keyed by `SourcedApp.id` so the path holds a string,
/// not a copy of the entry and its whole source.
struct AppRoute: Hashable {
    let id: String
}

struct BrowseView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.browsePath) {
            Group {
                if model.sources.isEmpty {
                    ContentUnavailableView {
                        Label("No Sources", systemImage: "tray")
                    } description: {
                        Text("Add an AltStore or PlayCover source to browse its apps.")
                    } actions: {
                        Button("Add a Source") { model.tab = .sources }
                            .primaryActionStyle()
                    }
                } else if model.browseResults.isEmpty && !model.filter.isUnfiltered {
                    ContentUnavailableView.search(text: model.filter.text)
                } else {
                    // List is lazy: rows, and their icon fetches, exist only on screen.
                    List(model.browseResults) { entry in
                        NavigationLink(value: AppRoute(id: entry.id)) {
                            AppRow(entry: entry)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Browse")
            .navigationDestination(for: AppRoute.self) { route in
                AppDetailView(entryID: route.id)
            }
            .searchable(text: $model.filter.text, prompt: "Apps, developers, bundle ids")
            .refreshable { await model.refreshAllSources() }
            .settingsToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Source", selection: $model.filter.source) {
                            Text("All Sources").tag(URL?.none)
                            ForEach(model.sources) { source in
                                Text(source.name).tag(URL?.some(source.url))
                            }
                        }
                    } label: {
                        Label("Filter by Source",
                              systemImage: "line.3.horizontal.decrease")
                    }
                    .disabled(model.sources.isEmpty)
                }
            }
        }
    }
}

/// One app in a list: icon, name, who made it, the latest version and size,
/// and where it stands against the library.
struct AppRow: View {
    @Environment(MobileModel.self) private var model
    let entry: SourcedApp

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: entry.app.iconURL, sourceURL: entry.sourceURL, side: 52, name: entry.app.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.app.name).font(.headline).lineLimit(1)
                Text(entry.app.subtitle ?? entry.app.developerName ?? entry.source.name)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if let latest = entry.app.latest {
                        Text(detail(latest)).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    statusPill
                }
                if let transfer = model.transfers[entry.id] {
                    TransferProgress(transfer: transfer)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func detail(_ version: CatalogVersion) -> String {
        var parts = [version.version]
        if let size = version.size { parts.append(Format.size(size)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private var statusPill: some View {
        switch model.status(of: entry) {
        case .notInstalled: EmptyView()
        case .installed: Pill(text: "Installed", systemImage: "checkmark", tint: .green)
        case .updateAvailable: Pill(text: "Update", systemImage: "arrow.down.circle", tint: .blue)
        }
    }
}
