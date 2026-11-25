import EiderKit
import SwiftUI

/// Installs and updates as the App Store shows downloads: what is running or
/// waiting on top, each with a ring that fills and stops on a click, and what
/// finished below.
struct ActivityView: View {
    let model: AppModel
    let activity: ActivityModel

    var body: some View {
        Group {
            if activity.items.isEmpty {
                ContentUnavailableView(
                    "No Activity", systemImage: "arrow.down.circle",
                    description: Text("Installs and updates appear here while they run."))
            } else {
                // Split once per draw: the list is short, but read it once.
                let pending = activity.items.filter(\.isPending)
                let finished = activity.items.filter { !$0.isPending }
                List {
                    if !pending.isEmpty {
                        Section("In Progress") {
                            ForEach(pending) { ActivityRow(model: model, item: $0, activity: activity) }
                        }
                    }
                    if !finished.isEmpty {
                        Section("Recent") {
                            ForEach(finished) { ActivityRow(model: model, item: $0, activity: activity) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem {
                Button("Clear Finished") { activity.clearFinished() }
                    .disabled(activity.items.allSatisfy(\.isPending))
            }
        }
    }
}

private struct ActivityRow: View {
    let model: AppModel
    let item: ActivityItem
    let activity: ActivityModel

    var body: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).lineLimit(1)
                status
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 6)
    }

    /// The app's icon when the request names a catalog entry or an installed
    /// app; a symbol tile for a file or an address.
    @ViewBuilder private var icon: some View {
        switch item.request {
        case .catalog(let app, _, let source):
            CatalogIcon(url: app.iconURL, sourceURL: source.url, name: app.name, side: 44)
        case .update(let bundleID, let name):
            if let installed = model.installed.first(where: { $0.bundleID == bundleID }) {
                InstalledIcon(app: installed, side: 44)
            } else {
                SymbolTile(symbol: "arrow.down.app", name: name)
            }
        case .url:
            SymbolTile(symbol: "link", name: "")
        case .localIPA:
            SymbolTile(symbol: "doc.zipper", name: "")
        }
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .queued:
            Text("Waiting").font(.callout).foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .leading, spacing: 5) {
                ProgressView(value: item.fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(maxWidth: 360)
                Text(progressLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
        case .failed(let code, let message):
            Text(message).font(.callout).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            Text(code).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        case .succeeded, .upToDate, .cancelled:
            Label(item.message, systemImage: doneSymbol)
                .font(.callout).foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
        }
    }

    private var doneSymbol: String {
        switch item.state {
        case .succeeded: return "checkmark.circle.fill"
        case .upToDate: return "checkmark.circle"
        default: return "xmark.circle"
        }
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .running, .queued:
            Button { activity.cancel(item.id) } label: {
                ProgressRing(fraction: item.fraction, side: 28, indeterminate: item.state == .queued)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
            .help("Cancel")
        default:
            if item.canRetry {
                Button("Retry") { activity.retry(item.id) }.rowCapsule()
            }
        }
    }

    private var progressLine: String {
        guard item.phase == .download, let received = item.bytesReceived else { return item.message }
        let done = Design.sizeText(received)
        guard let total = item.bytesTotal, total > 0 else { return "\(item.message): \(done)" }
        return "\(done) of \(Design.sizeText(total))"
    }
}

/// A flat squircle with a symbol, standing in for an app icon.
private struct SymbolTile: View {
    let symbol: String
    let name: String

    var body: some View {
        RoundedRectangle(cornerRadius: Design.iconCorner(44), style: .continuous)
            .fill(.quaternary)
            .overlay(Image(systemName: symbol).font(.title3.weight(.medium)).foregroundStyle(.secondary))
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }
}
