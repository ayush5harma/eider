import EiderCore
import SwiftUI

/// Five sections in the system TabView: a tab bar on iPhone, a sidebar on iPad
/// (iOS 18 and later), and Liquid Glass on iOS 26 without any work here.
struct RootView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        @Bindable var model = model
        tabs
            .sheet(item: $model.installRequest) { request in
                InstallSheet(request: request)
            }
            .sheet(isPresented: $model.showingSettings) {
                SettingsView()
            }
            .alert("Eider", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert(linkTitle, isPresented: Binding(
                get: { model.pendingLink != nil },
                set: { if !$0 { model.pendingLink = nil } })
            ) {
                Button("Cancel", role: .cancel) { model.pendingLink = nil }
                Button(linkAction) { Task { await model.confirmPendingLink() } }
            } message: {
                Text(linkMessage)
            }
    }

    @ViewBuilder private var tabs: some View {
        @Bindable var model = model
        if #available(iOS 18, *) {
            TabView(selection: $model.tab) {
                Tab("Browse", systemImage: "square.grid.2x2", value: AppTab.browse) { BrowseView() }
                Tab("Library", systemImage: "books.vertical", value: AppTab.library) { LibraryView() }
                Tab("Updates", systemImage: "arrow.down.circle", value: AppTab.updates) { UpdatesView() }
                    .badge(model.updates.count)
                Tab("Sources", systemImage: "tray.2", value: AppTab.sources) { SourcesView() }
                Tab("Certificates", systemImage: "checkmark.seal", value: AppTab.certificates) { CertificatesView() }
            }
            .tabViewStyle(.sidebarAdaptable)
        } else {
            TabView(selection: $model.tab) {
                BrowseView().tabItem { Label("Browse", systemImage: "square.grid.2x2") }.tag(AppTab.browse)
                LibraryView().tabItem { Label("Library", systemImage: "books.vertical") }.tag(AppTab.library)
                UpdatesView().tabItem { Label("Updates", systemImage: "arrow.down.circle") }.tag(AppTab.updates)
                    .badge(model.updates.count)
                SourcesView().tabItem { Label("Sources", systemImage: "tray.2") }.tag(AppTab.sources)
                CertificatesView().tabItem { Label("Certificates", systemImage: "checkmark.seal") }.tag(AppTab.certificates)
            }
        }
    }

    private var linkTitle: String {
        switch model.pendingLink {
        case .addSource?: "Add Source?"
        case .install?: "Download App?"
        case nil: ""
        }
    }

    private var linkAction: String {
        switch model.pendingLink {
        case .install?: "Download"
        default: "Add"
        }
    }

    private var linkMessage: String {
        switch model.pendingLink {
        case .addSource(let url)?: "A link asks Eider to add the source \(url.absoluteString)."
        case .install(let url)?: "A link asks Eider to download \(url.absoluteString) into your library."
        case nil: ""
        }
    }
}
