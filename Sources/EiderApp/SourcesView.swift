import AppKit
import EiderKit
import SwiftUI
import UniformTypeIdentifiers

/// The sources as a System Settings page: an Add section, the list of sources
/// with their state, and the news of the one selected. Grouped form, flat rows.
struct SourcesView: View {
    @Bindable var model: AppModel
    @State private var showingWarnings: CatalogSource?
    @State private var choosingImportFile = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    TextField("Address", text: $model.newSourceText, prompt: Text("https://example.com/apps.json"))
                        .onSubmit { Task { await model.addSourceFromText() } }
                    if model.isAddingSource {
                        ProgressView().controlSize(.small)
                        if let progress = model.sourceImportProgress {
                            Text(progress.label).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    Button("Add") { Task { await model.addSourceFromText() } }
                        .rowCapsule(prominent: true)
                        .disabled(model.newSourceText.isEmpty || model.isAddingSource)
                }
            } header: {
                Text("Add a Source")
            } footer: {
                Text("AltStore and PlayCover sources. Paste an https address, or the path of a source file on this Mac.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                if model.sources.isEmpty {
                    Text("No sources yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.sources, id: \.url) { source in
                        SourceRow(
                            model: model, source: source, failure: model.refreshFailures[source.url],
                            isSelected: model.selectedSourceURL == source.url
                        ) { showingWarnings = source }
                    }
                }
            } header: {
                HStack {
                    Text("Sources")
                    Spacer()
                    if model.isRefreshing {
                        ProgressView().controlSize(.mini)
                        Text("Refreshing...").foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Eider fetches sources older than six hours when it opens. A source that fails to refresh keeps its last copy.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }

            if let source = model.selectedSource {
                Section("News from \(source.name)") {
                    if source.news.isEmpty {
                        Text("This source has no news.").foregroundStyle(.secondary)
                    } else {
                        ForEach(source.news, id: \.identifier) { NewsRow(item: $0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sources")
        .navigationSubtitle(model.sources.count == 1 ? "1 source" : "\(model.sources.count) sources")
        .toolbar {
            ToolbarItemGroup {
                importExportMenu
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
        .sheet(isPresented: Binding(
            get: { model.sourceImportResult != nil }, set: { if !$0 { model.sourceImportResult = nil } })
        ) {
            if let result = model.sourceImportResult { ImportSummarySheet(result: result) }
        }
        .fileImporter(isPresented: $choosingImportFile, allowedContentTypes: [.json, .plainText]) { outcome in
            switch outcome {
            case .success(let url): Task { await model.importSources(fromFile: url) }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
    }

    private var importExportMenu: some View {
        Menu {
            Button("Import Sources...") { choosingImportFile = true }
                .accessibilityLabel("Import Sources...")
                .disabled(model.isAddingSource)
            Button("Import from Clipboard") { importFromClipboard() }
                .accessibilityLabel("Import from Clipboard")
                .disabled(model.isAddingSource)
            Divider()
            Button("Export Sources...") { exportSources() }
                .accessibilityLabel("Export Sources...")
                .disabled(model.sources.isEmpty)
            Button("Copy All Source URLs") { copyAllSourceURLs() }
                .accessibilityLabel("Copy All Source URLs")
                .disabled(model.sources.isEmpty)
        } label: {
            Label("Import and Export", systemImage: "square.and.arrow.up.on.square")
        }
        .accessibilityLabel("Import and Export")
        .help("Import sources from a file or the clipboard, or export the list")
    }

    private func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            model.errorMessage = "The clipboard has no text to import."
            return
        }
        Task { await model.importSources(from: Data(text.utf8)) }
    }

    private func copyAllSourceURLs() {
        let text = model.allSourceURLsText.trimmingCharacters(in: .newlines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// JSON by default; the chosen name decides, so "sources.txt" writes plain text.
    private func exportSources() {
        let panel = NSSavePanel()
        panel.title = "Export Sources"
        panel.nameFieldStringValue = "Eider Sources.json"
        panel.allowedContentTypes = [.json, .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.sourceListFile(named: url.lastPathComponent).write(to: url, options: .atomic)
        } catch {
            model.errorMessage = "Could not export the sources: \(error.localizedDescription)"
        }
    }
}

private struct ImportSummarySheet: View {
    let result: SourceImportResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Finished").font(.title3.bold())
            Text(result.summary).font(.headline)
            if result.hasProblems {
                List {
                    // Offsets, not addresses: several entries can be rejected under the same text.
                    ForEach(Array(result.rejected.enumerated()), id: \.offset) { row("Rejected", $0.element.url, $0.element.reason) }
                    ForEach(Array(result.failed.enumerated()), id: \.offset) { row("Failed", $0.element.url, $0.element.error) }
                }
                .frame(minHeight: 160)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).primaryActionStyle() }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func row(_ kind: String, _ address: String, _ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(address).font(.callout.monospaced()).lineLimit(2).truncationMode(.middle)
            Text("\(kind): \(reason)").font(.caption).foregroundStyle(.red)
        }
        .textSelection(.enabled)
        .padding(.vertical, 2)
    }
}

private struct SourceRow: View {
    let model: AppModel
    let source: CatalogSource
    let failure: String?
    let isSelected: Bool
    let showWarnings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CatalogIcon(url: source.iconURL, sourceURL: source.url, name: source.name, side: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(source.name).font(.headline).lineLimit(1)
                    if isSelected {
                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor)
                            .accessibilityLabel("Selected")
                    }
                }
                Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let failure {
                    Label("Last refresh failed: \(failure)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(source.apps.count == 1 ? "1 app" : "\(source.apps.count.formatted()) apps")
                    .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Text("Refreshed \(source.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.tertiary)
                if !source.warnings.isEmpty {
                    Button(source.warningsLabel, action: showWarnings)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Menu {
                Button("Show Apps in Browse") {
                    model.filter.source = source.url
                    model.selection = .browse
                }
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source.url.absoluteString, forType: .string)
                }
                if !source.warnings.isEmpty { Button("Show Warnings...", action: showWarnings) }
                Divider()
                Button("Remove Source", role: .destructive) { Task { await model.removeSource(source) } }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.borderless)
            .fixedSize()
            .accessibilityLabel("More actions for \(source.name)")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedSourceURL = isSelected ? nil : source.url }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

private struct NewsRow: View {
    let item: CatalogNews

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(.headline)
                Spacer()
                if let date = item.date {
                    Text(Design.dateText(date)).font(.caption).foregroundStyle(.tertiary)
                }
            }
            if let caption = item.caption { Text(caption).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
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
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).primaryActionStyle() }
        }
        .padding(20)
        .frame(width: 520, height: 340)
    }
}
