import AppKit
import EiderKit
import SwiftUI

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var uninstalling: InstalledApp?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 22, alignment: .top)]

    var body: some View {
        Group {
            if model.installed.isEmpty {
                ContentUnavailableView {
                    Label("No Apps Installed", systemImage: "square.grid.2x2")
                } description: {
                    Text("Find an app in Browse, or drop an .ipa file on this window.")
                } actions: {
                    Button("Browse Apps") { model.selection = .browse }
                    Button("Install IPA...") { chooseIPAFile(model) }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if !model.updates.isEmpty { updatesBanner }
                        LazyVGrid(columns: columns, spacing: 30) {
                            ForEach(model.installed) { app in
                                LibraryCell(model: model, app: app) { uninstalling = app }
                            }
                        }
                    }
                    .padding(.horizontal, Design.pagePadding).padding(.vertical, 26)
                }
            }
        }
        .navigationTitle("Library")
        .navigationSubtitle(model.installed.count == 1 ? "1 app" : "\(model.installed.count) apps")
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

    /// One line pointing at the Updates page, as the App Store's account page does.
    private var updatesBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title2).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.updates.count == 1 ? "1 update available" : "\(model.updates.count) updates available")
                    .font(.headline)
                Text("Newer versions are waiting in your sources.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Show Updates") { model.selection = .updates }.rowCapsule()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .cardBackground(cornerRadius: 14)
    }
}

/// An icon, a name and one action, as the App Store's purchased-apps grid
/// draws them: no card and no glass, so a large library scrolls cheaply.
private struct LibraryCell: View {
    let model: AppModel
    let app: InstalledApp
    let uninstall: () -> Void

    var body: some View {
        let hasUpdate = model.hasUpdate(app)
        VStack(spacing: 10) {
            InstalledIcon(app: app, side: 96)
                .overlay(alignment: .topTrailing) {
                    if hasUpdate {
                        Circle().fill(Color.accentColor)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2.5))
                            .offset(x: -2, y: 4)
                            .accessibilityHidden(true)
                    }
                }
            VStack(spacing: 4) {
                Text(app.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(app.version.isEmpty ? "Installed" : "Version \(app.version)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    if hasUpdate { UpdateBadge() }
                }
            }
            HStack(spacing: 6) {
                if hasUpdate {
                    Button("Update") { model.update(app) }.rowCapsule(prominent: true)
                } else {
                    Button("Open") { NSWorkspace.shared.open(app.path) }.rowCapsule()
                }
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .fixedSize()
                .accessibilityLabel("More actions for \(app.name)")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
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
            HStack(spacing: 14) {
                InstalledIcon(app: app, side: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Uninstall \(app.name)?").font(.title3.bold())
                    Text("The app is moved to the Trash.").foregroundStyle(.secondary)
                }
            }
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
