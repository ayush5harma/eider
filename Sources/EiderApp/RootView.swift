import AppKit
import EiderKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $model.selection) { section in
                Label(section.title, systemImage: Self.symbol(section))
                    .badge(badge(for: section))
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 240)
        } detail: {
            detail
        }
        .task {
            await model.reload()
            // Auto follows the display: rewrite it if Eider now runs on another one.
            if Shared.snapshotDirectory == nil { await model.refreshAutoInterfaceScales() }
            // The launch check: stale sources only, in the background. Not in a
            // snapshot run, whose pictures must not depend on the network.
            if Shared.snapshotDirectory == nil { await model.refreshStaleSources() }
        }
        .onChange(of: model.updates.count, initial: true) { _, count in
            NSApp.dockTile.badgeLabel = DockBadge.label(forUpdateCount: count)
        }
        .dropDestination(for: URL.self) { urls, _ in model.handleFiles(urls) }
        .sheet(item: $model.pendingInstall) { _ in InstallOptionsSheet(model: model) }
        .sheet(isPresented: Binding(get: { model.pendingLink != nil }, set: { if !$0 { model.dismissPendingLink() } })) {
            DeepLinkSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.diagnosis != .idle }, set: { if !$0 { model.dismissDiagnosis() } })) {
            DiagnosisSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { showsReleaseSheet }, set: { if !$0 { model.dismissReleaseCheck() } })) {
            ReleaseCheckSheet(model: model)
        }
        .alert("Eider", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .library: LibraryView(model: model)
        case .updates: UpdatesView(model: model)
        case .browse: BrowseView(model: model)
        case .activity: ActivityView(model: model, activity: model.activity)
        case .sources: SourcesView(model: model)
        }
    }

    private var showsReleaseSheet: Bool {
        switch model.releaseCheck {
        case .idle: return false
        default: return true
        }
    }

    private func badge(for section: SidebarSection) -> Int {
        switch section {
        case .updates: return model.updates.count
        case .activity: return model.activity.pendingCount
        default: return 0
        }
    }

    private static func symbol(_ section: SidebarSection) -> String {
        switch section {
        case .library: return "square.grid.2x2"
        case .updates: return "arrow.down.app"
        case .browse: return "storefront"
        case .activity: return "arrow.down.circle"
        case .sources: return "tray.2"
        }
    }
}
