import EiderCore
import SwiftUI

struct AppDetailView: View {
    @Environment(MobileModel.self) private var model
    let entryID: String

    var body: some View {
        if let entry = model.entry(id: entryID) {
            Detail(entry: entry)
        } else {
            ContentUnavailableView("App Not Listed", systemImage: "app.dashed",
                                   description: Text("Its source no longer lists this app."))
        }
    }
}

private struct Detail: View {
    @Environment(MobileModel.self) private var model
    let entry: SourcedApp
    @State private var showsFullDescription = false

    private var app: CatalogApp { entry.app }
    private var latest: CatalogVersion? { UpdateChecker.newestVersion(of: app) ?? app.latest }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                header
                infoStrip
                if !app.screenshots.isEmpty { screenshots }
                if let description = app.description, !description.isEmpty {
                    section("About") {
                        Text(DisplayText.sanitizedProse(description))
                            .font(.callout)
                            .lineLimit(showsFullDescription ? nil : 6)
                        Button(showsFullDescription ? "Less" : "More") { showsFullDescription.toggle() }
                            .font(.callout.weight(.semibold))
                    }
                }
                if let latest, let notes = latest.notes, !notes.isEmpty {
                    section("What's New") {
                        Text("Version \(latest.version)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Text(DisplayText.sanitizedProse(notes)).font(.callout).lineLimit(8)
                    }
                }
                versionHistory
            }
            .padding()
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            RemoteImage(url: app.iconURL, sourceURL: entry.sourceURL, size: CGSize(width: 104, height: 104), corner: 23, fallback: app.name)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.name).font(.title2.bold()).lineLimit(2)
                Text(app.developerName ?? entry.source.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                status
                Spacer(minLength: 4)
                getButton(for: latest, title: getTitle)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.status(of: entry) {
        case .notInstalled: EmptyView()
        case .installed(let version):
            Label("Installed \u{00B7} \(version)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .updateAvailable(let from, let to):
            Label("\(from) installed \u{00B7} \(to) available", systemImage: "arrow.down.circle.fill")
                .font(.caption).foregroundStyle(.blue)
        }
    }

    private var getTitle: String {
        if case .updateAvailable = model.status(of: entry) { return "Update" }
        return "Get"
    }

    @ViewBuilder private func getButton(for version: CatalogVersion?, title: String) -> some View {
        if let transfer = model.transfers[entry.id] {
            TransferProgress(transfer: transfer).frame(maxWidth: 140)
        } else if let version {
            Button(title) {
                Task { await model.get(entry, version: version) }
            }
            .primaryActionStyle()
            .accessibilityLabel("\(title) \(app.name) \(version.version)")
        }
    }

    private var infoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                if let latest {
                    info("Version", latest.version, footer: latest.date.map(Format.date) ?? "Latest")
                    if let size = latest.size { info("Size", Format.size(size), footer: "Download") }
                    if let minimum = latest.minOSVersion { info("Requires", "iOS \(minimum)", footer: "or later") }
                }
                info("Source", entry.source.name, footer: "\(app.versions.count) versions")
                if let category = app.category { info("Category", category.capitalized, footer: " ") }
            }
        }
    }

    private func info(_ title: String, _ value: String, footer: String) -> some View {
        VStack(spacing: 4) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            Text(footer).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 110)
        .padding(.vertical, 6)
        .overlay(alignment: .trailing) { Divider().frame(height: 36) }
    }

    private var screenshots: some View {
        section("Preview") {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(app.screenshots, id: \.self) { url in
                        RemoteImage(url: url, sourceURL: entry.sourceURL, size: CGSize(width: 196, height: 424), corner: 18, contentMode: .fit)
                    }
                }
            }
        }
    }

    private var versionHistory: some View {
        section("Version History") {
            if app.versions.isEmpty {
                Text("The source lists no versions.").foregroundStyle(.secondary)
            }
            ForEach(Array(app.versions.enumerated()), id: \.offset) { index, version in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(version.version).font(.headline.monospacedDigit())
                            if version == latest { Pill(text: "Latest", tint: .blue) }
                        }
                        Text(versionDetail(version)).font(.caption).foregroundStyle(.secondary)
                        if let notes = version.notes, !notes.isEmpty {
                            Text(DisplayText.sanitizedProse(notes)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                    Spacer()
                    if model.transfers[entry.id] == nil {
                        Button("Get") { Task { await model.get(entry, version: version) } }
                            .rowActionStyle()
                            .accessibilityLabel("Get version \(version.version)")
                    }
                }
                if index < app.versions.count - 1 { Divider() }
            }
        }
    }

    private func versionDetail(_ version: CatalogVersion) -> String {
        var parts: [String] = []
        if let build = version.build, build != version.version { parts.append("Build \(build)") }
        if let date = version.date { parts.append(Format.date(date)) }
        if let size = version.size { parts.append(Format.size(size)) }
        return parts.isEmpty ? " " : parts.joined(separator: " \u{00B7} ")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            content()
        }
    }
}
