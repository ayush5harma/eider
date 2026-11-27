import SwiftUI

/// Liquid Glass on iOS 26 and later for the few controls that stay put (Get,
/// Install, Add); the nearest older style before it. Never glass inside list
/// rows: a glass layer per row is an offscreen pass per row while scrolling.
extension View {
    @ViewBuilder func primaryActionStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }

    /// A neutral action beside a primary one, outside scrolling content.
    @ViewBuilder func secondaryActionStyle() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// A button inside a row: plain bordered, never glass.
    func rowActionStyle() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
    }

    /// A floating control that is not a button (the add bar's text field):
    /// interactive glass on 26, the bar material before it.
    @ViewBuilder func floatingSurface() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    /// Chrome pinned to the bottom of a screen: the system's scroll-edge bar
    /// on 26 (it blurs what scrolls under it), a plain inset before it.
    @ViewBuilder func bottomBar<Bar: View>(@ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .bottom) { bar() }
        } else {
            safeAreaInset(edge: .bottom) { bar().background(.bar) }
        }
    }

    /// Clusters of glass controls merge as one shape on 26.
    @ViewBuilder func glassCluster(spacing: CGFloat = 12) -> some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

/// An app icon: the iOS icon's continuous corner (about 22.37 percent of the
/// side), through the shared image pipeline.
struct AppIcon: View {
    let url: URL?
    let sourceURL: URL?
    let side: CGFloat
    var name: String = ""

    var body: some View {
        RemoteImage(url: url, sourceURL: sourceURL, size: CGSize(width: side, height: side),
                    corner: side * 0.2237, fallback: name)
    }
}

/// A small capsule label ("Installed", "Development", "Default"); flat, so
/// cheap in a list row.
struct Pill: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Progress for a download: determinate when the server gave a size.
struct TransferProgress: View {
    let transfer: Transfer

    var body: some View {
        if let fraction = transfer.fraction {
            ProgressView(value: fraction)
                .accessibilityLabel("Downloading, \(Int(fraction * 100)) percent")
        } else {
            ProgressView()
                .accessibilityLabel("Downloading")
        }
    }
}

enum Format {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

/// The settings gear every tab's navigation bar carries; Settings is a sheet
/// rather than a sixth tab so the five sections fit the iPhone tab bar.
struct SettingsToolbar: ViewModifier {
    @Environment(MobileModel.self) private var model

    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
    }
}

extension View {
    func settingsToolbar() -> some View { modifier(SettingsToolbar()) }
}
