import AppKit
import EiderKit

/// `--snapshot <dir>`: a verification aid, not a feature. Once the window is
/// up it shows each section, renders the window's content view to a PNG and
/// quits. `cacheDisplay` draws the view hierarchy itself, so it needs no
/// screen-recording permission and works while the window is behind others.
/// Success is recorded in `<dir>/snapshot.status` because `open` does not
/// report the exit status of the app it launched.
@MainActor
struct SnapshotRunner {
    let model: AppModel
    let directory: URL

    /// Time for SwiftUI to lay out and for icons to arrive after a selection
    /// change; 0.7 s was enough for the probe library on the development Mac.
    private static let settle: Duration = .milliseconds(700)
    /// A fixed size so the pictures compare from run to run, whatever the screen.
    private static let pageSize = NSSize(width: 1100, height: 720)
    /// The first page is drawn right after the window changes size; SwiftUI's
    /// hosting view lagged one pass behind on it (library.png came out at the
    /// old 2560-point width while the window was already 1100).
    private static let firstLayout: Duration = .seconds(1)
    private static let windowWait: Duration = .seconds(20)

    static func directory(from arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(index + 1) else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    func run() async {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let window = try await waitForWindow()
            // cacheDisplay renders a dark-mode window with the hosting view's
            // light background under light text (measured: white on white), so
            // the pictures are always drawn in the light appearance.
            window.appearance = NSAppearance(named: .aqua)
            try await fit(window)
            try await Task.sleep(for: Self.firstLayout)
            await model.reload()
            for section in SidebarSection.allCases {
                model.selection = section
                try await write(window, named: section.rawValue)
            }
            model.selection = .browse
            model.selectedAppID = model.browseResults.first?.id
            try await write(window, named: "browse-detail")
            try finish("ok")
        } catch {
            try? finish("failed: \(error)")
        }
    }

    private func waitForWindow() async throws -> NSWindow {
        let deadline = ContinuousClock.now + Self.windowWait
        while ContinuousClock.now < deadline {
            if let window = NSApp.windows.first(where: { $0.contentView != nil && $0.isVisible && $0.frame.width > 400 }) { return window }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SnapshotError.noWindow
    }

    private func write(_ window: NSWindow, named name: String) async throws {
        try await fit(window)
        try await Task.sleep(for: Self.settle)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let view = window.contentView, let page = Self.render(view, in: window) else { throw SnapshotError.cannotRender(name) }
        guard let png = page.representation(using: .png, properties: [:]) else { throw SnapshotError.cannotRender(name) }
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    /// `cacheDisplay` draws only what the views draw: the window's own
    /// background is not part of it, so in dark mode light text landed on
    /// transparent pixels and the PNG showed white on white (measured on the
    /// first run). The window background is painted first, in the window's own
    /// appearance, and the views drawn over it.
    private static func render(_ view: NSView, in window: NSWindow) -> NSBitmapImageRep? {
        let bounds = view.bounds
        guard let content = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: content)
        guard let page = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: content.pixelsWide, pixelsHigh: content.pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // The size (points) must be set before the context exists, or the
        // context draws at 1x into a 2x bitmap and fills a quarter of it.
        page.size = bounds.size
        guard let context = NSGraphicsContext(bitmapImageRep: page) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            bounds.fill()
        }
        content.draw(in: bounds)
        return page
    }

    /// Launched through `open`, the window comes up zoomed to the whole screen
    /// (measured: 2560 x 1409 points, zoomed = true) while a direct launch gives
    /// the 1100 x 720 default. Un-zoom first; a frame set while zoomed is undone.
    private func fit(_ window: NSWindow) async throws {
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: Self.pageSize)).size
        // Un-zooming animates, so wait until the frame has actually arrived.
        for _ in 0..<40 where window.frame.size != size {
            if window.isZoomed { window.zoom(nil) }
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finish(_ status: String) throws {
        try Data(status.utf8).write(to: directory.appendingPathComponent("snapshot.status"), options: .atomic)
        NSApp.terminate(nil)
    }
}

private enum SnapshotError: Error {
    case noWindow
    case cannotRender(String)
}
