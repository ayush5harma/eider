import EiderCore
import SwiftUI

/// An image from a source through the shared `ImagePipeline`, as on the Mac:
/// the address must pass `URLPolicy` for its source, the bitmap is decoded off
/// the main actor at the pixels this view covers, and the fetch is cancelled
/// when the row scrolls away. The body does no image work beyond a memory lookup.
struct RemoteImage: View {
    let url: URL?
    let sourceURL: URL?
    let size: CGSize
    var corner: CGFloat = 10
    var fallback: String = ""
    var contentMode: ContentMode = .fill

    @Environment(\.displayScale) private var displayScale
    @State private var loaded: Loaded?

    private struct Loaded {
        let request: ImageRequest
        let image: CGImage
    }

    var body: some View {
        let request = ImageRequest(
            url: url, sourceURL: sourceURL,
            pixelSize: Int((max(size.width, size.height) * displayScale).rounded(.up)))
        let image = loaded?.request == request ? loaded?.image : request.flatMap(ImagePipeline.shared.cachedImage)
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else {
                Placeholder(name: fallback, side: min(size.width, size.height))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
        .task(id: request) {
            guard let request, ImagePipeline.shared.cachedImage(for: request) == nil else { return }
            let fetched = await ImagePipeline.shared.image(for: request)
            if let fetched, !Task.isCancelled { loaded = Loaded(request: request, image: fetched) }
        }
    }
}

/// The first letter on a colour picked from the name: flat, so cheap in a list.
private struct Placeholder: View {
    let name: String
    let side: CGFloat

    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.52, blue: 0.86), Color(red: 0.52, green: 0.40, blue: 0.82),
        Color(red: 0.85, green: 0.45, blue: 0.48), Color(red: 0.89, green: 0.58, blue: 0.30),
        Color(red: 0.35, green: 0.66, blue: 0.55), Color(red: 0.30, green: 0.62, blue: 0.75),
        Color(red: 0.56, green: 0.58, blue: 0.64), Color(red: 0.74, green: 0.46, blue: 0.70),
    ]

    var body: some View {
        if let initial = name.first {
            let seed = name.unicodeScalars.prefix(3).reduce(0) { $0 &+ Int($1.value) }
            Rectangle().fill(Self.palette[seed % Self.palette.count].gradient)
                .overlay(
                    Text(String(initial).uppercased())
                        .font(.system(size: side * 0.44, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95)))
        } else {
            Rectangle().fill(.quaternary)
                .overlay(Image(systemName: "app.dashed").foregroundStyle(.tertiary))
        }
    }
}
