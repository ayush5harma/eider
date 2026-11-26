import EiderKit
import SwiftUI

/// An App Store product page. The header with the Install call to action
/// stays put and is the only glass on the page; the info strip, screenshots,
/// description, What's New, Information and Version History scroll beneath it
/// as flat content.
struct AppDetailView: View {
    let model: AppModel
    let entry: SourcedApp

    private var app: CatalogApp { entry.app }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    InfoStrip(items: infoItems)
                    if !app.screenshots.isEmpty { screenshots }
                    if let text = description { ExpandableText(text: text, lineLimit: 5) }
                    if let latest = app.latest { whatsNew(latest) }
                    information
                    if !app.versions.isEmpty { versionHistory }
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: Design.pageWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var description: String? {
        guard let text = app.description, !text.isEmpty else { return nil }
        return text
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            CatalogIcon(url: app.iconURL, sourceURL: entry.sourceURL, name: app.name, side: 108)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.largeTitle.weight(.bold)).lineLimit(2)
                if let subtitle = app.subtitle {
                    Text(subtitle).font(.title3).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(app.developerName ?? entry.source.name)
                    .font(.callout).foregroundStyle(Color.accentColor).lineLimit(1)
                if let latest = app.latest {
                    HStack(spacing: 10) {
                        installButton(for: latest, title: "Install \(latest.version)", visible: "Install")
                            .primaryActionStyle()
                            .controlSize(.large)
                        statusLine(latest)
                    }
                    .padding(.top, 8)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Beside the button: what Install would bring, or how the installed copy stands.
    @ViewBuilder private func statusLine(_ latest: CatalogVersion) -> some View {
        switch model.status(of: entry) {
        case .notInstalled:
            Text(detail(of: latest).isEmpty ? "Version \(latest.version)" : "Version \(latest.version) · \(detail(of: latest))")
                .font(.callout).foregroundStyle(.secondary)
        case .installed(let version):
            Label("Installed\(version.isEmpty ? "" : " · Version \(version)")", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.secondary)
        case .updateAvailable(let from, let to):
            HStack(spacing: 6) {
                UpdateBadge()
                Text("Version \(from) installed · \(to) available")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Info strip

    /// Five columns fit the narrowest detail pane without cutting a word; the
    /// source moves to Information when the strip is full.
    private static let stripLimit = 5

    private var infoItems: [InfoStrip.Item] {
        var items: [InfoStrip.Item] = []
        if let latest = app.latest {
            items.append(.init(title: "Version", value: .text(latest.version), footer: latest.date.map(Design.dateText) ?? "Latest"))
            if let size = latest.size {
                let parts = Design.sizeText(size).split(separator: " ", maxSplits: 1).map(String.init)
                items.append(.init(title: "Size", value: .text(parts.first ?? ""), footer: parts.count > 1 ? parts[1] : ""))
            }
            if let minimum = latest.minOSVersion {
                items.append(.init(title: "Requires", value: .symbol("iphone"), footer: "iOS \(minimum)+"))
            }
        }
        if let category = app.category {
            items.append(.init(title: "Category", value: .symbol("square.grid.2x2"), footer: category))
        }
        if let developer = app.developerName {
            items.append(.init(title: "Developer", value: .symbol("person.crop.square"), footer: developer))
        }
        if items.count < Self.stripLimit {
            items.append(.init(title: "Source", value: .symbol("tray.2"), footer: entry.source.name))
        }
        return Array(items.prefix(Self.stripLimit))
    }

    // MARK: Sections

    private var screenshots: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Preview")
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(app.screenshots, id: \.self) {
                        RemoteImage(
                            url: $0, sourceURL: entry.sourceURL, size: CGSize(width: 170, height: 340),
                            corner: 18, contentMode: .fit)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screenshots of \(app.name)")
    }

    private func whatsNew(_ latest: CatalogVersion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "What's New")
            HStack(alignment: .firstTextBaseline) {
                Text("Version \(latest.version)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let date = latest.date {
                    Text(Design.dateText(date)).font(.callout).foregroundStyle(.secondary)
                }
            }
            let notes = latest.notes.map(DisplayText.sanitizedProse) ?? ""
            if notes.isEmpty {
                Text("The source gives no notes for this version.").foregroundStyle(.tertiary)
            } else {
                ExpandableText(text: notes, lineLimit: 4)
            }
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Information")
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 28, verticalSpacing: 0) {
                ForEach(Array(informationRows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary)
                        Text(row.1).textSelection(.enabled).lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 9)
                }
            }
            .font(.callout)
        }
    }

    private var informationRows: [(String, String)] {
        var rows: [(String, String)] = [("Source", entry.source.name)]
        if let developer = app.developerName { rows.append(("Developer", developer)) }
        if let latest = app.latest {
            rows.append(("Version", latest.build.map { "\(latest.version) (\($0))" } ?? latest.version))
            if let size = latest.size { rows.append(("Size", Design.sizeText(size))) }
            if let minimum = latest.minOSVersion { rows.append(("Compatibility", "iOS \(minimum) or later")) }
        }
        if let category = app.category { rows.append(("Category", category)) }
        rows.append(("Identifier", app.bundleID))
        if let latest = app.latest { rows.append(("Download Check", model.integrityNote(for: latest))) }
        return rows
    }

    private var versionHistory: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Version History", detail: app.versions.count > 1 ? "\(app.versions.count) versions" : nil)
            VStack(spacing: 0) {
                ForEach(Array(app.versions.enumerated()), id: \.element) { index, version in
                    if index > 0 { Divider() }
                    versionRow(version, isLatest: index == 0)
                }
            }
        }
    }

    private func versionRow(_ version: CatalogVersion, isLatest: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(version.version).font(.headline.monospacedDigit())
                    if isLatest { Pill(text: "Latest", tint: .accentColor) }
                    Spacer(minLength: 8)
                    Text(detail(of: version)).font(.callout).foregroundStyle(.secondary)
                }
                if let notes = version.notes.map(DisplayText.sanitizedProse), !notes.isEmpty {
                    Text(notes).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            installButton(for: version, title: "Install", visible: "Install").rowCapsule()
                .controlSize(.small)
        }
        .padding(.vertical, 12)
    }

    private func detail(of version: CatalogVersion) -> String {
        var parts: [String] = []
        if let date = version.date { parts.append(Design.dateText(date)) }
        if let size = version.size { parts.append(Design.sizeText(size)) }
        return parts.joined(separator: " · ")
    }

    /// `title` makes the accessibility label the owner's automation reads
    /// ("Install 3.2 Aurora Notes 3.2", "Install Aurora Notes 3.1"); `visible`
    /// is what the button shows.
    private func installButton(for version: CatalogVersion, title: String, visible: String) -> some View {
        Button(visible) {
            model.requestInstall(.catalog(app: app, version: version, source: entry.source))
        }
        .accessibilityLabel("\(title) \(app.name) \(version.version)")
    }
}

/// The strip under an App Store product header: short columns of a caption, a
/// value and a footnote, divided by hairlines. Flat, in the scrolling content.
struct InfoStrip: View {
    enum Value {
        case text(String)
        case symbol(String)
    }

    struct Item {
        let title: String
        let value: Value
        let footer: String
    }

    let items: [Item]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Divider().frame(height: 46).padding(.top, 6) }
                VStack(spacing: 5) {
                    Text(item.title.uppercased())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                    Group {
                        switch item.value {
                        case .text(let text): Text(text).font(.title2.weight(.semibold)).monospacedDigit()
                        case .symbol(let name): Image(systemName: name).font(.title2.weight(.medium))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(height: 26)
                    Text(item.footer).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.vertical, 4)
    }
}
