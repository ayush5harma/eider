import EiderKit
import SwiftUI

struct AppDetailView: View {
    let model: AppModel
    let entry: SourcedApp

    private var app: CatalogApp { entry.app }

    var body: some View {
        // The header with the Install call to action stays put; only the
        // description, screenshots and versions scroll, so the glass button is
        // never inside scrolling content.
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if let text = app.description, !text.isEmpty {
                        Text(text).lineSpacing(3).textSelection(.enabled)
                            .frame(maxWidth: 680, alignment: .leading)
                    }
                    if !app.screenshots.isEmpty { screenshots }
                    if !app.versions.isEmpty { versions }
                    Label("From \(entry.source.name)", systemImage: "tray.full")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                RemoteImage(
                    url: app.iconURL, sourceURL: entry.sourceURL, size: CGSize(width: 96, height: 96),
                    corner: 22, fallback: app.name)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.title.weight(.bold)).lineLimit(2)
                    if let developer = app.developerName {
                        Text(developer).font(.title3).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let subtitle = app.subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    StatusTag(status: model.status(of: app)).padding(.top, 2)
                }
                Spacer(minLength: 12)
                if let latest = app.latest {
                    VStack(alignment: .trailing, spacing: 6) {
                        installButton(for: latest, title: "Install \(latest.version)")
                            .primaryActionStyle()
                            .controlSize(.large)
                        Text(detail(of: latest)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let latest = app.latest {
                Label(model.integrityNote(for: latest), systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Screenshots").font(.title3.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(app.screenshots, id: \.self) {
                        RemoteImage(
                            url: $0, sourceURL: entry.sourceURL, size: CGSize(width: 150, height: 300),
                            corner: 12, contentMode: .fit)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screenshots of \(app.name)")
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Versions").font(.title3.weight(.semibold))
            VStack(spacing: 0) {
                ForEach(Array(app.versions.enumerated()), id: \.element) { index, version in
                    if index > 0 { Divider().padding(.leading, 16) }
                    versionRow(version, isLatest: index == 0)
                }
            }
            .cardBackground(cornerRadius: 12)
        }
    }

    private func versionRow(_ version: CatalogVersion, isLatest: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(version.version).font(.body.weight(.semibold).monospacedDigit())
                    if isLatest { Pill(text: "Latest", tint: .accentColor) }
                }
                Text(detail(of: version)).font(.caption).foregroundStyle(.secondary)
                if let notes = version.notes, !notes.isEmpty {
                    Text(notes).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            Spacer(minLength: 8)
            installButton(for: version, title: "Install").rowActionStyle()
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private func detail(of version: CatalogVersion) -> String {
        var parts: [String] = []
        if let date = version.date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let size = version.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.isEmpty ? "No date or size given" : parts.joined(separator: " · ")
    }

    private func installButton(for version: CatalogVersion, title: String) -> some View {
        Button(title) {
            model.requestInstall(.catalog(app: app, version: version, source: entry.source))
        }
        .accessibilityLabel("\(title) \(app.name) \(version.version)")
    }
}
