import CoreGraphics
import Foundation
import XCTest
@testable import EiderCore
@testable import EiderKit

/// What a Browse row pays for its icon. The row's own body only ever does the
/// synchronous memory lookup; fetching and decoding happen elsewhere and must
/// leave the main actor free. Bounds are wide so a loaded machine does not
/// flake them; the numbers go to the log with the prefix `IMAGE-PERF`.
@MainActor
final class ImagePipelinePerformanceTests: XCTestCase {
    private static let lookups = 10_000
    private static let decodes = 120

    private func milliseconds(_ block: () async -> Void) async -> Double {
        let start = ContinuousClock.now
        await block()
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    func testAMemoryHitCostsMicrosecondsOnTheMainActor() async throws {
        let pipeline = ImagePipeline(store: nil, loader: LoaderProbe().loader(body: ImageFixtures.png(side: 512), delay: .zero))
        let requests = (0..<200).map { ImageFixtures.request("\($0).png") }
        for request in requests { _ = await pipeline.image(for: request) }
        var hits = 0
        let elapsed = await milliseconds {
            for i in 0..<Self.lookups where pipeline.cachedImage(for: requests[i % requests.count]) != nil { hits += 1 }
        }
        XCTAssertEqual(hits, Self.lookups)
        let perLookup = elapsed * 1000 / Double(Self.lookups)
        print("IMAGE-PERF \(Self.lookups) memory hits on the main actor: \(elapsed) ms, \(perLookup) us each")
        // A frame is 8-16 ms; 36 visible rows must cost a small part of one.
        XCTAssertLessThan(perLookup, 50)
    }

    /// Decodes 1024-pixel icons down to row size while a main-actor heartbeat
    /// ticks every millisecond: the longest gap between ticks is how long the
    /// main thread was held. A decode on the main actor would show up here as
    /// a gap of the decode's length times the batch.
    func testDecodingAndDownsamplingStayOffTheMainActor() async throws {
        let big = ImageFixtures.png(side: 1024)
        let pipeline = ImagePipeline(store: nil, loader: LoaderProbe().loader(body: big, delay: .zero))

        let single = await milliseconds { _ = ImageDecoder.downsample(big, maxPixelSize: 72) }
        let full = await milliseconds { _ = ImageDecoder.downsample(big, maxPixelSize: 1024) }
        print("IMAGE-PERF one 1024 px PNG: downsampled to 72 px \(single) ms, decoded at full size \(full) ms")

        let idle = await heartbeat(during: { try? await Task.sleep(for: .milliseconds(300)) })
        var decoded = 0
        var batch = 0.0
        let loaded = await heartbeat(during: {
            batch = await self.milliseconds {
                await withTaskGroup(of: Bool.self) { group in
                    for i in 0..<Self.decodes {
                        group.addTask { await pipeline.image(for: ImageFixtures.request("\(i).png")) != nil }
                    }
                    for await ok in group where ok { decoded += 1 }
                }
            }
        })
        XCTAssertEqual(decoded, Self.decodes)
        print("IMAGE-PERF \(Self.decodes) fetch+downsample to 72 px: \(batch) ms")
        print("IMAGE-PERF main-actor heartbeat (1 ms sleeps): idle \(idle.ticks) ticks, longest gap \(idle.gap) ms; while decoding \(loaded.ticks) ticks, longest gap \(loaded.gap) ms")
        // Decoding 120 icons on the main actor would hold it for 120 x ~10 ms,
        // over a second. Measured off it: 12 ms alone, 39 ms once inside the
        // full suite with every core busy, so the bound leaves room for that.
        XCTAssertLessThan(loaded.gap, 200, "the main actor was held while images decoded")
    }

    /// Runs `work` while a main-actor task sleeps 1 ms at a time, and returns
    /// how often it woke and the longest it waited.
    private func heartbeat(during work: () async -> Void) async -> (ticks: Int, gap: Double) {
        var longest = 0.0
        var ticks = 0
        let beat = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1))
                let gap = ContinuousClock.now - last
                longest = max(longest, Double(gap.components.seconds) * 1000 + Double(gap.components.attoseconds) / 1e15)
                last = ContinuousClock.now
                ticks += 1
            }
        }
        await work()
        beat.cancel()
        _ = await beat.value
        return (ticks, longest)
    }
}
