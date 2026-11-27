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

    /// A button inside a row: plain bordered, never glass.
    func rowActionStyle() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
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
