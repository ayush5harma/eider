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
        .task { await model.reload() }
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
        case .library: return model.updates.count
        case .activity: return model.activity.items.filter(\.isRunning).count
        default: return 0
        }
    }

    private static func symbol(_ section: SidebarSection) -> String {
        switch section {
        case .library: return "square.grid.2x2"
        case .browse: return "magnifyingglass"
        case .activity: return "arrow.down.circle"
        case .sources: return "tray.full"
        }
    }
}
