// Draws Resources/AppIcon.icns from original geometry (CoreGraphics only, no
// SF Symbols, no third-party artwork). Usage:
//   swift Scripts/make-icon.swift Resources/AppIcon.icns
// The script renders an iconset of the ten standard sizes into a temporary
// directory, then calls /usr/bin/iconutil, which ships with macOS.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Rounded square inset ~10% so the icon keeps the standard margin.
    let inset = s * 0.1
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tilePath = CGPath(
        roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225,
        transform: nil)
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.16, green: 0.36, blue: 0.52, alpha: 1),
            CGColor(red: 0.05, green: 0.14, blue: 0.27, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
    ctx.restoreGState()

    // Feather: a leaf-shaped vane plus a quill, in units of half the tile
    // edge, rotated so the tip points to the upper right.
    ctx.saveGState()
    ctx.translateBy(x: tile.midX, y: tile.midY)
    ctx.rotate(by: -.pi / 4)
    let u = tile.width * 0.5
    let paper = CGColor(red: 0.97, green: 0.97, blue: 0.95, alpha: 1)
    let vane = CGMutablePath()
    vane.move(to: CGPoint(x: 0, y: 0.62 * u))
    vane.addCurve(
        to: CGPoint(x: 0, y: -0.62 * u),
        control1: CGPoint(x: 0.55 * u, y: 0.30 * u),
        control2: CGPoint(x: 0.55 * u, y: -0.30 * u))
    vane.addCurve(
        to: CGPoint(x: 0, y: 0.62 * u),
        control1: CGPoint(x: -0.40 * u, y: -0.30 * u),
        control2: CGPoint(x: -0.40 * u, y: 0.30 * u))
    ctx.setFillColor(paper)
    ctx.addPath(vane)
    ctx.fillPath()

    // Quill in the background colour over the vane, then a short stem past
    // the base in the vane colour.
    ctx.setLineCap(.round)
    ctx.setStrokeColor(CGColor(red: 0.10, green: 0.25, blue: 0.40, alpha: 1))
    ctx.setLineWidth(max(1, s * 0.018))
    ctx.move(to: CGPoint(x: 0, y: 0.50 * u))
    ctx.addLine(to: CGPoint(x: 0, y: -0.50 * u))
    ctx.strokePath()
    ctx.setStrokeColor(paper)
    ctx.setLineWidth(max(1, s * 0.022))
    ctx.move(to: CGPoint(x: 0, y: -0.62 * u))
    ctx.addLine(to: CGPoint(x: 0, y: -0.86 * u))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fputs("could not write \(url.path)\n", stderr)
        exit(1)
    }
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift make-icon.swift <output.icns>\n", stderr)
    exit(2)
}
let output = CommandLine.arguments[1]
let work = FileManager.default.temporaryDirectory
    .appendingPathComponent("eider-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

for base in [16, 32, 128, 256, 512] {
    writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(
        render(size: base * 2),
        to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
