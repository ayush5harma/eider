import EiderCore
import SwiftUI

struct UpdatesView: View {
    @Environment(MobileModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.updates.isEmpty {
                    ContentUnavailableView {
                        Label("No Updates", systemImage: "checkmark.circle")
                    } description: {
                        Text(model.installed.isEmpty
                             ? "Apps you install with Eider are checked against your sources here."
                             : "Every app Eider installed is up to date with your sources.")
                    }
                } else {
                    List(model.updates) { offer in
                        UpdateRow(offer: offer)
                    }
                }
            }
            .navigationTitle("Updates")
            .refreshable { await model.refreshAllSources() }
            .settingsToolbar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isUpdatingAll {
                        ProgressView()
                    } else {
                        Button("Update All") { Task { await model.updateAll() } }
                            .disabled(model.updates.isEmpty)
                    }
                }
            }
        }
    }
}

private struct UpdateRow: View {
    @Environment(MobileModel.self) private var model
    let offer: UpdateOffer<InstalledApp>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                RemoteImage(url: offer.app.iconURL, sourceURL: offer.sourceURL, size: CGSize(width: 52, height: 52), corner: 12, fallback: offer.app.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.installed.name).font(.headline).lineLimit(1)
                    Text("\(offer.installed.version) \u{2192} \(offer.version.version)")
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    Text([offer.sourceName.isEmpty ? nil : offer.sourceName, offer.version.size.map(Format.size)]
                        .compactMap { $0 }.joined(separator: " \u{00B7} "))
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                if let transfer = model.transfers[offer.id] {
                    TransferProgress(transfer: transfer).frame(width: 64)
                } else {
                    Button("Update") { Task { await model.update(offer) } }
                        .rowActionStyle()
                        .disabled(model.isUpdatingAll)
                }
            }
            if let job = model.updateJobs[offer.id] {
                StepList(job: job).font(.caption)
            }
            if let notes = offer.version.notes, !notes.isEmpty {
                Text(DisplayText.sanitizedProse(notes)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.vertical, 2)
    }
}
