import EiderCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist (UTImportedTypeDeclarations), so it resolves.
    static let ipa = UTType("com.apple.itunes.ipa") ?? UTType(filenameExtension: "ipa") ?? .zip
}

struct LibraryView: View {
    @Environment(MobileModel.self) private var model
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.installed.isEmpty {
                        Text("Apps you install with Eider appear here, and Updates follows them.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.installed) { app in
                        InstalledRow(app: app, sourceName: model.sourceName(for: app.origin?.sourceURL ?? app.sourceURL))
                            .swipeActions {
                                Button("Forget", role: .destructive) { Task { await model.forget(app) } }
                            }
                    }
                } header: {
                    Text("Installed by Eider")
                }

                Section {
                    if model.ipas.isEmpty {
                        Text("Download an app from Browse, or import an IPA from Files.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.ipas) { ipa in
                        Button {
                            model.installRequest = InstallRequest(ipa: ipa)
                        } label: {
                            IPARow(ipa: ipa)
                        }
                        .foregroundStyle(.primary)
                        .swipeActions {
                            Button("Delete", role: .destructive) { Task { await model.deleteIPA(ipa) } }
                        }
                        .contextMenu {
                            Button("Install", systemImage: "arrow.down.app") { model.installRequest = InstallRequest(ipa: ipa) }
                            Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteIPA(ipa) } }
                        }
                    }
                } header: {
                    Text("IPAs")
                } footer: {
                    Text("Tap an IPA to sign and install it. IPAs shared to Eider from Files or another app land here too.")
                }
            }
            .navigationTitle("Library")
            .settingsToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        importing = true
                    } label: {
                        Label("Import IPA", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.ipa]) { outcome in
                switch outcome {
                case .success(let url): Task { await model.importIPA(from: url) }
                case .failure(let error): model.report(error)
                }
            }
        }
    }
}

private struct InstalledRow: View {
    let app: InstalledApp
    let sourceName: String?

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: app.iconURL, sourceURL: app.origin?.sourceURL ?? app.sourceURL,
                        size: CGSize(width: 48, height: 48), corner: 11, fallback: app.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).lineLimit(1)
                Text("\(app.version) \u{00B7} \(app.bundleID)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text([sourceName, "Installed \(Format.date(app.installedAt))"].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }
}

private struct IPARow: View {
    let ipa: LibraryIPA

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: ipa.iconURL, sourceURL: ipa.origin?.sourceURL, size: CGSize(width: 48, height: 48), corner: 11, fallback: ipa.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(ipa.name).font(.headline).lineLimit(1)
                Text([ipa.version, Format.size(ipa.size), "Added \(Format.date(ipa.addedAt))"].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "arrow.down.app").foregroundStyle(.tint)
        }
    }
}
