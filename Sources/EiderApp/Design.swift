import AppKit
import EiderKit
import SwiftUI

/// The shapes and pieces every page shares, after the Mac App Store: app icons
/// as continuous squircles, section titles in the system's title style, flat
/// fills inside scrolling content (no glass per row, see Glass.swift).
enum Design {
    /// The App Store's icon mask is a continuous rounded square of about 22.5% of the side.
    static func iconCorner(_ side: CGFloat) -> CGFloat { (side * 0.225).rounded() }

    /// The readable width for a product page or the Updates list.
    static let pageWidth: CGFloat = 860
    static let pagePadding: CGFloat = 32

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// A catalog app's icon at App Store proportions, through the image pipeline.
struct CatalogIcon: View {
    let url: URL?
    let sourceURL: URL?
    let name: String
    let side: CGFloat

    var body: some View {
        RemoteImage(
            url: url, sourceURL: sourceURL, size: CGSize(width: side, height: side),
            corner: Design.iconCorner(side), fallback: name)
    }
}

/// An installed app's own icon. `NSWorkspace.icon(forFile:)` reads the bundle
/// from disk; a page that redraws often asked again every time, so the image
/// is kept per path for the life of the process (an update replaces the bundle
/// at the same path, and the icon of an app rarely changes with it).
struct InstalledIcon: View {
    let app: InstalledApp
    let side: CGFloat

    var body: some View {
        Image(nsImage: InstalledIconCache.icon(for: app.path))
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }
}

@MainActor
enum InstalledIconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for url: URL) -> NSImage {
        if let cached = icons[url.path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[url.path] = icon
        return icon
    }
}

/// A section title in the App Store's style: a bold title, optionally a quiet
/// detail on the same line and an action at the far end.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.title3).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// Text cut to a few lines with a "more" link, as the App Store does for
/// descriptions and release notes. Whether the text is long is judged from its
/// length and line breaks, not by measuring layout, so the body stays cheap.
struct ExpandableText: View {
    let text: String
    var lineLimit = 4
    var font: Font = .body

    @State private var expanded = false

    private var isLong: Bool {
        text.count > lineLimit * 90 || text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= lineLimit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(font)
                .lineSpacing(2)
                .lineLimit(expanded ? nil : lineLimit)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLong {
                Button(expanded ? "Less" : "More") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .buttonStyle(.link)
                .font(font)
            }
        }
    }
}

/// The App Store's download control: a ring that fills, with a stop square in
/// the middle that cancels. Flat strokes only, so it is cheap in a row.
struct ProgressRing: View {
    let fraction: Double
    var side: CGFloat = 26
    var indeterminate = false

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            if indeterminate {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: fraction)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: side * 0.3, height: side * 0.3)
            }
        }
        .frame(width: side, height: side)
    }
}

/// The capsule a list row uses for its one action (Update, Open, Retry):
/// the App Store's grey pill with accent text. Bordered, never glass, because
/// rows scroll.
struct RowCapsuleStyle: ViewModifier {
    var prominent = false

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            // A bordered button on the Mac ignores the tint for its title, so
            // the accent is set on the label, as the App Store's pills have it.
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).foregroundStyle(Color.accentColor)
        }
    }
}

extension View {
    func rowCapsule(prominent: Bool = false) -> some View {
        modifier(RowCapsuleStyle(prominent: prominent)).fontWeight(.semibold)
    }
}

/// "Last checked 5 minutes ago", kept current once a minute.
struct LastCheckedText: View {
    let date: Date?
    let isChecking: Bool

    var body: some View {
        if isChecking {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Checking for updates...")
            }
        } else if let date {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("Last checked \(Self.relative(date, now: context.date))")
            }
        } else {
            Text("Add a source to check for updates")
        }
    }

    static func relative(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
