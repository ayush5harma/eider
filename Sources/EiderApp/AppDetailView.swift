import EiderKit
import SwiftUI

struct AppDetailView: View {
    let model: AppModel
    let entry: SourcedApp

    private var app: CatalogApp { entry.app }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let latest = app.latest {
                    VStack(alignment: .leading, spacing: 4) {
                        installButton(for: latest, title: "Install \(latest.version)")
                        Text(model.integrityNote(for: latest)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let text = app.description, !text.isEmpty { Text(text).textSelection(.enabled) }
                if !app.screenshots.isEmpty { screenshots }
                if !app.versions.isEmpty { versions }
                Text("From \(entry.source.name)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            RemoteImage(url: app.iconURL, size: CGSize(width: 72, height: 72), corner: 16, fallback: app.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.title2.bold())
                if let developer = app.developerName { Text(developer).foregroundStyle(.secondary) }
                if let subtitle = app.subtitle { Text(subtitle).font(.callout) }
                StatusTag(status: model.status(of: app))
            }
        }
    }

    private var screenshots: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(app.screenshots, id: \.self) {
                    RemoteImage(url: $0, size: CGSize(width: 150, height: 300), corner: 8, fallback: "")
                }
            }
        }
        .accessibilityLabel("Screenshots of \(app.name)")
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Versions").font(.headline)
            ForEach(app.versions, id: \.self) { version in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(version.version).bold()
                        Text(detail(of: version)).font(.caption).foregroundStyle(.secondary)
                        if let notes = version.notes, !notes.isEmpty { Text(notes).font(.callout).lineLimit(4) }
                    }
                    Spacer()
                    installButton(for: version, title: "Install")
                }
                Divider()
            }
        }
    }

    private func detail(of version: CatalogVersion) -> String {
        var parts: [String] = []
        if let date = version.date { parts.append(date.formatted(date: .abbreviated, time: .omitted)) }
        if let size = version.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.isEmpty ? "No date or size given" : parts.joined(separator: "  ")
    }

    private func installButton(for version: CatalogVersion, title: String) -> some View {
        Button(title) {
            model.requestInstall(.catalog(app: app, version: version, source: entry.source))
        }
        .accessibilityLabel("\(title) \(app.name) \(version.version)")
    }
}

/// An image from a source. Only addresses the URL policy allows are loaded, and
/// only when this view is on screen, which is after the person picked the app.
struct RemoteImage: View {
    let url: URL?
    let size: CGSize
    let corner: CGFloat
    let fallback: String

    var body: some View {
        Group {
            if let url, URLPolicy.isAllowed(url) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() } else { placeholder }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: corner).fill(.quaternary)
            .overlay(Text(String(fallback.prefix(1))).font(.title2).foregroundStyle(.secondary))
    }
}
