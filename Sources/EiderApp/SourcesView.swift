import EiderKit
import SwiftUI

struct SourcesView: View {
    @Bindable var model: AppModel
    @State private var showingWarnings: CatalogSource?

    var body: some View {
        VStack(spacing: 0) {
            addBar
            Divider()
            if model.sources.isEmpty {
                ContentUnavailableView(
                    "No sources", systemImage: "tray",
                    description: Text("Paste the address of an AltStore or PlayCover source above."))
            } else {
                table
                Divider()
                news.frame(height: 220)
            }
        }
        .navigationTitle("Sources")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshAllSources() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || model.sources.isEmpty)
                .help("Fetch every source again (Command-R)")
                Button {
                    if let source = model.selectedSource { Task { await model.removeSource(source) } }
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(model.selectedSource == nil)
                .help("Remove the selected source")
            }
        }
        .sheet(item: $showingWarnings) { WarningsSheet(source: $0) }
    }

    private var addBar: some View {
        HStack {
            TextField("Source address (https://...)", text: $model.newSourceText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.addSourceFromText() } }
            Button("Add") { Task { await model.addSourceFromText() } }
                .disabled(model.newSourceText.isEmpty || model.isAddingSource)
            if model.isAddingSource || model.isRefreshing { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    private var table: some View {
        List(model.sources, id: \.url, selection: $model.selectedSourceURL) { source in
            SourceRow(source: source, failure: model.refreshFailures[source.url]) { showingWarnings = source }
                .tag(source.url)
        }
    }

    @ViewBuilder private var news: some View {
        if let source = model.selectedSource {
            if source.news.isEmpty {
                ContentUnavailableView("No news from \(source.name)", systemImage: "newspaper")
            } else {
                List(source.news, id: \.identifier) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.headline)
                        if let caption = item.caption { Text(caption).font(.callout).foregroundStyle(.secondary) }
                        if let date = item.date { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a source to see its news", systemImage: "newspaper")
        }
    }
}

private struct SourceRow: View {
    let source: CatalogSource
    let failure: String?
    let showWarnings: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name).font(.headline)
                Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let failure { Text("Last refresh failed: \(failure)").font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            Text("\(source.apps.count) apps").foregroundStyle(.secondary)
            Text("Refreshed \(source.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
            if !source.warnings.isEmpty {
                Button("\(source.warnings.count) warnings", action: showWarnings)
                    .buttonStyle(.link)
            }
        }
    }
}

private struct WarningsSheet: View {
    let source: CatalogSource
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Warnings from \(source.name)").font(.title3.bold())
            Text("Entries Eider skipped or values it ignored while reading this source.").font(.callout).foregroundStyle(.secondary)
            List(source.warnings, id: \.self) { Text($0).textSelection(.enabled) }
                .frame(minHeight: 160)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 520, height: 340)
    }
}
