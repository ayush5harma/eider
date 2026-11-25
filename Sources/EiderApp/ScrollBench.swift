import AppKit
import EiderKit

/// A verification aid for the snapshot run, not a feature: scrolls the Browse
/// list down and back up, one step per 16 ms frame, and records what the main
/// thread paid. Two measures, because SwiftUI does part of its row work in the
/// synchronous layout and display a scroll triggers and part on later turns of
/// the run loop (the icon tasks landing):
///
/// - per frame: the wall time of scroll + layout + display, called directly;
/// - overall: the main thread's own CPU time (Mach thread info) across the run,
///   divided by the frames, which catches the deferred work too.
///
/// Results go to `scroll-bench.txt` in the snapshot directory.
@MainActor
struct ScrollBench {
    let model: AppModel
    let window: NSWindow
    let steps: Int

    /// About 9,400 points a second at 60 Hz: a brisk trackpad fling.
    static let pointsPerFrame: CGFloat = 156
    static let frame: Duration = .milliseconds(16)

    func run(writingTo directory: URL) async throws {
        model.selectedAppID = nil
        model.selection = .browse
        await model.settleBrowse()
        try await Task.sleep(for: .seconds(1))
        // The sidebar is a table too; the browse list is the long one.
        guard let table = Self.all(NSTableView.self, in: window.contentView).max(by: { $0.numberOfRows < $1.numberOfRows }),
              let scroll = table.enclosingScrollView else {
            throw ScrollBenchError.noList
        }
        let fetchesBefore = await ImagePipeline.shared.networkFetches
        let cpuBefore = Self.mainThreadCPU()
        let started = ContinuousClock.now

        let down = try await pass(scroll, from: 0, by: Self.pointsPerFrame)
        let bottom = scroll.contentView.bounds.origin.y
        let up = try await pass(scroll, from: bottom, by: -Self.pointsPerFrame)

        let wall = Self.milliseconds(ContinuousClock.now - started)
        let cpu = (Self.mainThreadCPU() - cpuBefore) * 1000
        let fetches = await ImagePipeline.shared.networkFetches - fetchesBefore
        let rowHeight = table.numberOfRows > 0 ? table.rect(ofRow: 0).height : 0
        let frames = down.count + up.count
        let lines = [
            "catalog rows: \(model.browseResults.count), row height \(rowHeight) pt, \(Self.pointsPerFrame) pt per frame",
            "scrolled down \(Int(bottom)) pt (~\(rowHeight > 0 ? Int(bottom / rowHeight) : 0) rows) in \(down.count) frames, then back up in \(up.count)",
            "down (icons fetched and decoded): \(Self.summary(down))",
            "up (icons from memory): \(Self.summary(up))",
            "main-thread CPU over the run: \(Self.format(cpu)) ms in \(Self.format(wall)) ms wall, \(Self.format(cpu / Double(max(frames, 1)))) ms per frame",
            "image fetches started during the run: \(fetches)",
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("scroll-bench.txt"), options: .atomic)
    }

    /// Up to `steps / 2` frames from `start` in steps of `delta`, stopping at
    /// either end of the list. Returns the synchronous cost of each frame.
    private func pass(_ scroll: NSScrollView, from start: CGFloat, by delta: CGFloat) async throws -> [Double] {
        let maxY = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        var y = start
        var samples: [Double] = []
        for _ in 0..<max(1, steps / 2) {
            y = min(max(0, y + delta), maxY)
            let begin = ContinuousClock.now
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            window.layoutIfNeeded()
            window.displayIfNeeded()
            samples.append(Self.milliseconds(ContinuousClock.now - begin))
            try await Task.sleep(for: Self.frame)
            if y == 0 || y == maxY { break }
        }
        return samples
    }

    private static func summary(_ samples: [Double]) -> String {
        guard !samples.isEmpty else { return "no frames" }
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let over8 = samples.filter { $0 > 8.33 }.count
        let over16 = samples.filter { $0 > 16.67 }.count
        return "\(samples.count) frames, mean \(format(mean)) ms, p50 \(format(percentile(0.5))) ms, "
            + "p95 \(format(percentile(0.95))) ms, p99 \(format(percentile(0.99))) ms, max \(format(sorted.last ?? 0)) ms, "
            + "over 8.3 ms: \(over8), over 16.7 ms: \(over16)"
    }

    private static func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// User + system CPU seconds of the calling (main) thread.
    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let thread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, thread) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return user + system
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        let own: [T] = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { all(type, in: $0) }
    }
}

private enum ScrollBenchError: Error {
    case noList
}
