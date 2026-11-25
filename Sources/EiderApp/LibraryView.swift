import AppKit
import EiderKit
import SwiftUI

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var uninstalling: InstalledApp?

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 18)]

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
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(model.installed) { app in
                            LibraryCell(model: model, app: app) { uninstalling = app }
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                Button { chooseIPAFile(model) } label: {
                    Label("Install IPA...", systemImage: "plus")
                }
                .help("Install an .ipa file from disk (Command-O)")
            }
        }
        .sheet(item: $uninstalling) { app in UninstallSheet(model: model, app: app) }
    }
}

/// A plain card, not glass: the grid scrolls, and the tiles are drawn as
/// opaque fills with a hairline so a large library scrolls without a blur pass
/// per tile.
private struct LibraryCell: View {
    let model: AppModel
    let app: InstalledApp
    let uninstall: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
                .padding(.top, 4)
            VStack(spacing: 3) {
                Text(app.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text("Version \(app.version)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if model.hasUpdate(app) { UpdateBadge() }
                }
            }
            HStack(spacing: 6) {
                Button("Open") { NSWorkspace.shared.open(app.path) }
                    .buttonStyle(.bordered)
                if model.hasUpdate(app) {
                    Button("Update") { model.update(app) }
                        .buttonStyle(.borderedProminent)
                }
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .fixedSize()
                .accessibilityLabel("More actions for \(app.name)")
            }
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.vertical, 16).padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .cardBackground(cornerRadius: 16)
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
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
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
