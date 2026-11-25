import EiderKit
import SwiftUI

struct ActivityView: View {
    let model: AppModel
    let activity: ActivityModel

    var body: some View {
        Group {
            if activity.items.isEmpty {
                ContentUnavailableView(
                    "No activity", systemImage: "arrow.down.circle",
                    description: Text("Installs and updates appear here while they run."))
            } else {
                List(activity.items) { item in
                    ActivityRow(item: item, activity: activity)
                        .padding(.vertical, 6)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem {
                Button("Clear Finished") { activity.clearFinished() }
                    .disabled(activity.items.allSatisfy(\.isRunning))
            }
        }
    }
}

private struct ActivityRow: View {
    let item: ActivityItem
    let activity: ActivityModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            symbol
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.headline)
                    Spacer(minLength: 8)
                    if item.isRunning {
                        Text(item.fraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    trailing
                }
                switch item.state {
                case .running:
                    ProgressView(value: item.fraction)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)
                    Text(progressLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                case .failed(let code, let message):
                    Text(message).foregroundStyle(.red)
                    Text(code).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                case .succeeded, .upToDate, .cancelled:
                    Text(item.message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Flat circle and symbol: rows scroll, so no glass here.
    private var symbol: some View {
        let (name, tint): (String, Color) = switch item.state {
        case .running: (item.phase == .install ? "shippingbox" : "arrow.down", .accentColor)
        case .succeeded, .upToDate: ("checkmark", .green)
        case .cancelled: ("xmark", .secondary)
        case .failed: ("exclamationmark", .red)
        }
        return Image(systemName: name)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }

    @ViewBuilder private var trailing: some View {
        if item.isRunning {
            Button("Cancel") { activity.cancel(item.id) }.rowActionStyle()
        } else if item.canRetry {
            Button("Retry") { activity.retry(item.id) }.rowActionStyle()
        }
    }

    private var progressLine: String {
        guard item.phase == .download, let received = item.bytesReceived else { return item.message }
        let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let total = item.bytesTotal, total > 0 else { return "\(item.message): \(done)" }
        return "\(item.message): \(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}
