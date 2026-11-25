import SwiftUI

/// Liquid Glass on macOS 26 and later, the nearest older control or material
/// before it (the package still supports macOS 14). Glass is for chrome that
/// stays put: calls to action, the add bar, toolbars. Never inside a List or
/// ScrollView row: one glass layer per row is an offscreen pass per row while
/// scrolling 17,000 of them.
extension View {
    /// The one action a screen is about (Install, Add).
    @ViewBuilder func primaryActionStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }

    /// A neutral action beside a primary one, outside scrolling content.
    @ViewBuilder func secondaryActionStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }

    /// A button inside scrolling content: plain bordered, never glass.
    func rowActionStyle() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
    }

    /// A card inside scrolling content: an opaque fill and a hairline, no blur
    /// and no shadow. The control background is white on the light window
    /// background and lifted grey on the dark one, so the card reads in both.
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// A small capsule label ("Installed", "Latest", "12 apps"); flat, so it is
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
        .background(tint.opacity(0.12), in: Capsule())
    }
}
