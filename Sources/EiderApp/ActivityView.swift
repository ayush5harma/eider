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
                        .padding(.vertical, 4)
                }
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.title).font(.headline)
                Spacer()
                trailing
            }
            switch item.state {
            case .running:
                ProgressView(value: item.fraction)
                Text(progressLine).font(.caption).foregroundStyle(.secondary)
            case .failed(let code, let message):
                Text(message).foregroundStyle(.red)
                Text(code).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            case .succeeded, .upToDate, .cancelled:
                Text(item.message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if item.isRunning {
            Button("Cancel") { activity.cancel(item.id) }
        } else if item.canRetry {
            Button("Retry") { activity.retry(item.id) }
        }
    }

    private var progressLine: String {
        guard item.phase == .download, let received = item.bytesReceived else { return item.message }
        let done = ByteCountFormatter.string(fromByteCount: received, countStyle: .file)
        guard let total = item.bytesTotal, total > 0 else { return "\(item.message): \(done)" }
        return "\(item.message): \(done) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
    }
}
