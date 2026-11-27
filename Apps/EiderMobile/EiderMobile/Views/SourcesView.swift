import EiderCore
import SwiftUI
import UniformTypeIdentifiers

struct SourcesView: View {
    @Environment(MobileModel.self) private var model
    @State private var choosingImportFile = false
    @State private var exporting = false
    @State private var exportDocument: SourceListDocument?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                if let progress = model.importProgress {
                    Section {
                        ProgressView("Importing \(progress.done) of \(progress.total)...",
                                     value: Double(progress.done), total: Double(max(progress.total, 1)))
                    }
                }

                Section {
                    if model.sources.isEmpty {
                        Text("No sources yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.sources) { source in
                        NavigationLink(value: source.url) {
                            SourceRow(source: source, failure: model.refreshFailures[source.url])
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                Task { await model.removeSource(source) }
                            }
                        }
                        .contextMenu {
                            Button("Copy Address", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = source.url.absoluteString
                            }
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                Task { await model.removeSource(source) }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Sources")
                        if model.isRefreshing { Spacer(); ProgressView().controlSize(.small) }
                    }
                } footer: {
                    Text("AltStore and PlayCover sources. Pull to refresh; Eider also fetches sources older than six hours when it opens; a source that fails keeps its last copy.")
                }
            }
            .navigationTitle("Sources")
            .navigationDestination(for: URL.self) { url in
                SourceDetailView(sourceURL: url)
            }
            .refreshable { await model.refreshAllSources() }
            .bottomBar { AddSourceBar() }
            .modifier(RefreshItem(isRefreshing: model.isRefreshing) { Task { await model.refreshAllSources() } })
            .settingsToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Import from Files", systemImage: "folder") { choosingImportFile = true }
                        Button("Import from Clipboard", systemImage: "doc.on.clipboard") {
                            guard let text = UIPasteboard.general.string else {
                                model.errorMessage = "The clipboard has no text."
                                return
                            }
                            Task { await model.importSources(from: Data(text.utf8)) }
                        }
                        Divider()
                        Button("Export...", systemImage: "square.and.arrow.up") {
                            do {
                                exportDocument = SourceListDocument(data: try model.exportedSourceList())
                                exporting = true
                            } catch {
                                model.report(error)
                            }
                        }
                        .disabled(model.sources.isEmpty)
                        Button("Copy All URLs", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = model.allSourceURLsText
                        }
                        .disabled(model.sources.isEmpty)
                    } label: {
                        Label("Import and Export", systemImage: "ellipsis")
                    }
                    .disabled(model.isAddingSource)
                }
            }
            .fileImporter(isPresented: $choosingImportFile, allowedContentTypes: [.json, .plainText, .text]) { outcome in
                switch outcome {
                case .success(let url): Task { await model.importSources(fromFile: url) }
                case .failure(let error): model.report(error)
                }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                          defaultFilename: "Eider Sources.json") { outcome in
                if case .failure(let error) = outcome { model.report(error) }
            }
            .sheet(item: Binding(
                get: { model.importResult.map(ImportResultBox.init) },
                set: { if $0 == nil { model.importResult = nil } })
            ) { box in
                ImportResultView(result: box.result)
            }
        }
    }
}

/// The add field as floating glass chrome above the tab bar, so it stays in
/// reach however long the list gets: field, Paste and Add merge as one cluster.
private struct AddSourceBar: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let empty = model.newSourceText.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(spacing: 10) {
            TextField("Add a source: https://...", text: $model.newSourceText)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { Task { await model.addSourceFromText() } }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .floatingSurface()
            if empty {
                PasteButton(payloadType: String.self) { strings in
                    if let text = strings.first { model.newSourceText = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
            } else if model.isAddingSource {
                ProgressView().frame(width: 44, height: 44)
            } else {
                Button {
                    Task { await model.addSourceFromText() }
                } label: {
                    Image(systemName: "plus").font(.body.weight(.semibold)).frame(width: 22, height: 26)
                }
                .primaryActionStyle()
                .buttonBorderShape(.circle)
                .accessibilityLabel("Add Source")
            }
        }
        .glassCluster()
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

/// Refresh beside the import menu, in its own glass group on 26
/// (ToolbarSpacer), so the two do not read as one control.
private struct RefreshItem: ViewModifier {
    let isRefreshing: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.toolbar {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
                ToolbarItem(placement: .topBarTrailing) { button }
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .topBarTrailing) { button }
            }
        }
    }

    @ViewBuilder private var button: some View {
        if isRefreshing {
            ProgressView()
        } else {
            Button(action: action) { Label("Refresh All", systemImage: "arrow.clockwise") }
        }
    }
}

private struct SourceRow: View {
    let source: CatalogSource
    let failure: String?

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: source.iconURL, sourceURL: source.url, side: 44, name: source.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name).font(.headline).lineLimit(1)
                let count = source.entryCount ?? source.apps.count
                Text("\(count == 1 ? "1 app" : "\(count) apps") \u{00B7} Refreshed \(Format.relative(source.fetchedAt))")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if !source.warnings.isEmpty {
                    Pill(text: source.warnings.count == 1 ? "1 warning" : "\(source.warnings.count) warnings",
                         systemImage: "exclamationmark.triangle", tint: .orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// One source: what it says about itself, its warnings, and its apps.
private struct SourceDetailView: View {
    @Environment(MobileModel.self) private var model
    let sourceURL: URL

    var body: some View {
        if let source = model.sources.first(where: { $0.url == sourceURL }) {
            List {
                Section {
                    HStack(spacing: 14) {
                        AppIcon(url: source.iconURL, sourceURL: source.url, side: 64, name: source.name)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).font(.title2.bold())
                            if let subtitle = source.subtitle { Text(subtitle).foregroundStyle(.secondary) }
                        }
                    }
                    if let description = source.description, !description.isEmpty {
                        Text(DisplayText.sanitizedProse(description)).font(.callout).foregroundStyle(.secondary)
                    }
                    LabeledContent("Address") {
                        Text(source.url.absoluteString).textSelection(.enabled).lineLimit(2)
                    }
                    LabeledContent("Refreshed", value: source.fetchedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if !source.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(Array(source.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Apps") {
                    ForEach(SourcedApp.entries(of: source)) { entry in
                        NavigationLink(value: AppRoute(id: entry.id)) {
                            AppRow(entry: entry)
                        }
                    }
                }
            }
            .navigationTitle(source.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppRoute.self) { route in
                AppDetailView(entryID: route.id)
            }
        } else {
            ContentUnavailableView("Source Removed", systemImage: "tray")
        }
    }
}

private struct ImportResultBox: Identifiable {
    let id = UUID()
    let result: SourceImportResult
}

/// The Mac's import summary: "Added 2 · 1 already added · 1 rejected", then
/// one line per rejected or failed address with its reason.
private struct ImportResultView: View {
    @Environment(\.dismiss) private var dismiss
    let result: SourceImportResult

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(result.summary).font(.headline)
                }
                if result.hasProblems {
                    Section("Not Added") {
                        ForEach(result.rejected, id: \.url) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.url).font(.callout).lineLimit(2)
                                Text("Rejected: \(line.reason)").font(.caption).foregroundStyle(.red)
                            }
                        }
                        ForEach(result.failed, id: \.url) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.url).font(.callout).lineLimit(2)
                                Text("Failed: \(line.error)").font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Import Finished")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// The exported source list (Eider's JSON format, docs/SOURCES.md).
struct SourceListDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
