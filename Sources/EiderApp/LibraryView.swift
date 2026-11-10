import AppKit
import EiderKit
import SwiftUI

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var uninstalling: InstalledApp?

    private let columns = [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 16)]

    var body: some View {
        Group {
            if model.installed.isEmpty {
                ContentUnavailableView {
                    Label("No apps installed", systemImage: "square.grid.2x2")
                } description: {
                    Text("Find an app in Browse, or drop an .ipa file on this window.")
                } actions: {
                    Button("Browse Apps") { model.selection = .browse }
                    Button("Install IPA...") { chooseIPAFile(model) }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(model.installed) { app in
                            LibraryCell(model: model, app: app) { uninstalling = app }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle("Library")
        .sheet(item: $uninstalling) { app in UninstallSheet(model: model, app: app) }
    }
}

private struct LibraryCell: View {
    let model: AppModel
    let app: InstalledApp
    let uninstall: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path.path))
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text(app.name).font(.headline).lineLimit(1)
            HStack(spacing: 6) {
                Text("Version \(app.version)").font(.caption).foregroundStyle(.secondary)
                if model.hasUpdate(app) { UpdateBadge() }
            }
            HStack {
                Button("Open") { NSWorkspace.shared.open(app.path) }
                if model.hasUpdate(app) {
                    Button("Update") { model.update(app) }
                }
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More actions for \(app.name)")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .contextMenu { actions }
    }

    @ViewBuilder private var actions: some View {
        Button("Open") { NSWorkspace.shared.open(app.path) }
        if model.hasUpdate(app) { Button("Update") { model.update(app) } }
        Button("Diagnose") { Task { await model.diagnose(app) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app.path]) }
        Divider()
        Button("Uninstall...", role: .destructive, action: uninstall)
    }
}

struct UpdateBadge: View {
    var body: some View {
        Text("Update")
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
            .foregroundStyle(.white)
    }
}

private struct UninstallSheet: View {
    let model: AppModel
    let app: InstalledApp
    @State private var removeData = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall \(app.name)?").font(.title3.bold())
            Text("The app is moved to the Trash.")
            Toggle("Also remove its data", isOn: $removeData)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) {
                    dismiss()
                    Task { await model.uninstall(app, removeData: removeData) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
