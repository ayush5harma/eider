import AppKit
import EiderKit
import SwiftUI

/// The App Store's Updates page: what has a newer version in its source, with
/// Update per row and Update All in the toolbar, then what was installed
/// lately. The list comes from `AppModel.updateList`, worked out off the main
/// actor at each reload; this view only draws it.
struct UpdatesView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.updateList.isEmpty && model.recentInstalls.isEmpty {
                ContentUnavailableView {
                    Label("All apps are up to date", systemImage: "checkmark.circle")
                } description: {
                    LastCheckedText(date: model.lastUpdateCheck, isChecking: model.isRefreshing)
                } actions: {
                    Button("Check for Updates") { Task { await model.refreshAllSources() } }
                        .disabled(model.isRefreshing || model.sources.isEmpty)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 34) {
                        available
                        if !model.recentInstalls.isEmpty { recent }
                    }
                    .padding(.horizontal, Design.pagePadding).padding(.vertical, 26)
                    .frame(maxWidth: Design.pageWidth, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Updates")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await model.refreshAllSources() }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || model.sources.isEmpty)
                .help("Fetch every source again and look for updates (Command-R)")
                Button("Update All") { model.updateAll() }
                    .primaryActionStyle()
                    .disabled(!canUpdateAll)
                    .accessibilityLabel("Update All")
                    .help("Update every app, one after another")
            }
        }
    }

    private var subtitle: String {
        switch model.updateList.count {
        case 0: return "Up to date"
        case 1: return "1 update available"
        case let count: return "\(count) updates available"
        }
    }

    private var canUpdateAll: Bool {
        model.updateList.contains { !model.isUpdating($0.installed.bundleID) }
    }

    @ViewBuilder private var available: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: model.updateList.isEmpty ? "All apps are up to date" : "Available") {
                LastCheckedText(date: model.lastUpdateCheck, isChecking: model.isRefreshing)
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !model.updateList.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(model.updateList.enumerated()), id: \.element.id) { index, update in
                        if index > 0 { Divider().padding(.leading, 78) }
                        UpdateRow(model: model, update: update)
                    }
                }
                .padding(.horizontal, 18)
                .cardBackground(cornerRadius: 16)
            }
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Installed Recently")
            VStack(spacing: 0) {
                ForEach(Array(model.recentInstalls.enumerated()), id: \.element.id) { index, app in
                    if index > 0 { Divider().padding(.leading, 78) }
                    RecentRow(app: app)
                }
            }
            .padding(.horizontal, 18)
            .cardBackground(cornerRadius: 16)
        }
    }
}

private struct UpdateRow: View {
    let model: AppModel
    let update: AvailableUpdate

    @State private var showsNotes = false

    private var name: String { update.installed.name }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            icon
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.headline).lineLimit(1)
                        HStack(spacing: 5) {
                            Text(update.installed.version.isEmpty ? "Installed" : update.installed.version)
                            Image(systemName: "arrow.right").imageScale(.small).accessibilityLabel("to")
                            Text(update.version.version).foregroundStyle(.primary)
                        }
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    action
                }
                notes
            }
        }
        .padding(.vertical, 14)
    }

    /// The installed bundle's own icon when the source has none: it is the app
    /// on this Mac either way.
    @ViewBuilder private var icon: some View {
        if update.app.iconURL != nil {
            CatalogIcon(url: update.app.iconURL, sourceURL: update.sourceURL, name: name, side: 62)
        } else {
            InstalledIcon(app: update.installed, side: 62)
        }
    }

    private var details: String {
        var parts = [update.sourceName.isEmpty ? update.sourceURL.host() ?? update.sourceURL.lastPathComponent : update.sourceName]
        if let date = update.version.date { parts.append(Design.dateText(date)) }
        if let size = update.version.size { parts.append(Design.sizeText(size)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var action: some View {
        if let item = model.updateActivity(for: update.installed.bundleID) {
            Button { model.activity.cancel(item.id) } label: {
                if item.state == .queued {
                    Text("Waiting").font(.callout).foregroundStyle(.secondary)
                } else {
                    ProgressRing(fraction: item.fraction, indeterminate: item.phase == .install && item.fraction < 0.01)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel updating \(name)")
            .help(item.message)
        } else {
            Button("Update") { model.update(update.installed, showActivity: false) }
                .rowCapsule()
                .accessibilityLabel("Update \(name)")
        }
    }

    @ViewBuilder private var notes: some View {
        let text = update.version.notes.map(DisplayText.sanitizedProse) ?? ""
        if text.isEmpty {
            Text("The source gives no notes for this version.").font(.callout).foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy) { showsNotes.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text("What's New").font(.callout.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(showsNotes ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(showsNotes ? "Hide what's new in \(name)" : "Show what's new in \(name)")
                if showsNotes {
                    ExpandableText(text: text, lineLimit: 6, font: .callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct RecentRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 16) {
            InstalledIcon(app: app, side: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.headline).lineLimit(1)
                Text(app.version.isEmpty ? "Installed" : "Version \(app.version)")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Text(Design.dateText(app.installedAt)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Open") { NSWorkspace.shared.open(app.path) }
                .rowCapsule()
                .accessibilityLabel("Open \(app.name)")
        }
        .padding(.vertical, 12)
    }
}
