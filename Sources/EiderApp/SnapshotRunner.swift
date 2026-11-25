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
            try await fit(window)
            try await Task.sleep(for: Self.firstLayout)
            await model.reload()
            // Light pictures keep their old names; the dark set gets a suffix.
            // Painting the window background in the window's own appearance
            // (render below) is what makes the dark set legible.
            for (appearance, suffix) in [(NSAppearance.Name.aqua, ""), (.darkAqua, "-dark")] {
                NSApp.appearance = NSAppearance(named: appearance)
                window.appearance = NSAppearance(named: appearance)
                try await writePages(window, suffix: suffix)
            }
            if let steps = Self.scrollBenchSteps {
                window.appearance = NSAppearance(named: .aqua)
                try await ScrollBench(model: model, window: window, steps: steps).run(writingTo: directory)
            }
            try finish("ok")
        } catch {
            try? finish("failed: \(error)")
        }
    }

    private func writePages(_ window: NSWindow, suffix: String) async throws {
        model.selectedAppID = nil
        for section in SidebarSection.allCases {
            model.selection = section
            try await write(window, named: section.rawValue + suffix)
        }
        model.selection = .browse
        await model.settleBrowse()
        model.selectedAppID = model.browseResults.first?.id
        try await write(window, named: "browse-detail" + suffix)
        // An app with an update shows the status pill and the version list.
        if let update = model.browseResults.first(where: {
            if case .updateAvailable = model.status(of: $0.app) { return true } else { return false }
        }) {
            model.selectedAppID = update.id
            try await write(window, named: "browse-update" + suffix)
        }
    }

    /// `EIDER_SCROLL_BENCH=<frames>`: after the pictures, scroll Browse that
    /// many frames and record the main-thread cost of each (ScrollBench).
    private static var scrollBenchSteps: Int? {
        ProcessInfo.processInfo.environment["EIDER_SCROLL_BENCH"].flatMap(Int.init).map { max(1, $0) }
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
        // The frame view, not the content view: the toolbar with its search
        // field and source picker is part of what the pictures are for.
        guard let view = window.contentView?.superview ?? window.contentView,
              let page = Self.render(view, in: window) else { throw SnapshotError.cannotRender(name) }
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
