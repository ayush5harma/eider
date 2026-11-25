// Draws Resources/AppIcon.icns from original geometry (CoreGraphics only, no
// SF Symbols, no third-party artwork). Usage:
//   swift Scripts/make-icon.swift Resources/AppIcon.icns
// The script renders an iconset of the ten standard sizes into a temporary
// directory, then calls /usr/bin/iconutil, which ships with macOS.
//
// The picture is the app's namesake: a drake common eider floating at dawn,
// facing right, with the species' colour blocks (white back and breast, black
// flanks, rump and crown cap, sea-green nape) and its long wedge bill running
// straight on from the forehead. Behind it an app-shaped sun rises from the
// sea: iPhone apps arriving on the Mac. Sizes of 32 px and under drop the sun,
// the ripples and the small highlights and draw the duck larger, because at
// that size only the bold shapes survive.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// Apple's continuous-corner rounded rectangle (the "squircle"): each corner
// is three cubic segments that start 1.52866 r along the edge, so curvature
// ramps up instead of jumping as it does on a circular-arc corner.
func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    // One corner, drawn for the top-right in a frame whose origin is that
    // corner, x running back along the top edge and y down the right edge.
    let corner: [(CGPoint, CGPoint, CGPoint)] = [
        (p(1.08849, 0), p(0.86840, 0), p(0.66993, 0.06480)),
        (p(0.37282, 0.16906), p(0.16906, 0.37282), p(0.06480, 0.66993)),
        (p(0, 0.86840), p(0, 1.08849), p(0, 1.52866)),
    ]
    // (corner point, direction "back along the edge", direction "into the next edge")
    let frames: [(CGPoint, CGVector, CGVector)] = [
        (p(rect.maxX, rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (p(rect.maxX, rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (p(rect.minX, rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (p(rect.minX, rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    for (index, (origin, back, down)) in frames.enumerated() {
        func map(_ q: CGPoint) -> CGPoint {
            p(origin.x + (back.dx * q.x + down.dx * q.y) * r,
              origin.y + (back.dy * q.x + down.dy * q.y) * r)
        }
        let start = map(p(1.52866, 0))
        if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
        for (c1, c2, end) in corner {
            path.addCurve(to: map(end), control1: map(c1), control2: map(c2))
        }
    }
    path.closeSubpath()
    return path
}

// MARK: - The duck, in tile units (0...1, y up)

let waterline: CGFloat = 0.255
let horizon: CGFloat = 0.47

func duckBody() -> CGPath {
    let b = CGMutablePath()
    b.move(to: p(0.17, waterline))
    b.addCurve(to: p(0.085, 0.395), control1: p(0.12, 0.27), control2: p(0.085, 0.33))
    b.addCurve(to: p(0.27, 0.47), control1: p(0.12, 0.43), control2: p(0.19, 0.47))
    b.addCurve(to: p(0.57, 0.50), control1: p(0.38, 0.49), control2: p(0.50, 0.51))
    b.addCurve(to: p(0.76, 0.37), control1: p(0.70, 0.50), control2: p(0.77, 0.45))
    b.addCurve(to: p(0.66, waterline), control1: p(0.755, 0.30), control2: p(0.71, waterline))
    b.closeSubpath()
    return b
}

// Head, neck and bill as one outline. The top line from the crown runs
// straight down to the bill tip: the eider's wedge profile.
func duckHead() -> CGPath {
    let h = CGMutablePath()
    // Starts on the back so the nape flows into it without a notch.
    h.move(to: p(0.38, 0.488))
    h.addCurve(to: p(0.468, 0.640), control1: p(0.452, 0.497), control2: p(0.468, 0.56))
    h.addCurve(to: p(0.575, 0.762), control1: p(0.470, 0.715), control2: p(0.515, 0.762))
    h.addCurve(to: p(0.650, 0.738), control1: p(0.610, 0.762), control2: p(0.632, 0.752))
    h.addLine(to: p(0.840, 0.592))
    h.addCurve(to: p(0.828, 0.558), control1: p(0.858, 0.578), control2: p(0.850, 0.556))
    h.addLine(to: p(0.700, 0.566))
    h.addCurve(to: p(0.760, 0.390), control1: p(0.668, 0.545), control2: p(0.700, 0.440))
    h.closeSubpath()
    return h
}

// Where the feathering meets the bill: the bill's frontal lobe pushes back
// into the forehead as a point, as it does on the real bird.
func billRegion() -> CGPath {
    let r = CGMutablePath()
    r.move(to: p(0.64, 0.80))
    r.addLine(to: p(0.672, 0.725))
    r.addCurve(to: p(0.654, 0.676), control1: p(0.660, 0.712), control2: p(0.650, 0.690))
    r.addCurve(to: p(0.700, 0.556), control1: p(0.680, 0.650), control2: p(0.700, 0.600))
    r.addLine(to: p(0.95, 0.45))
    r.addLine(to: p(0.95, 0.80))
    r.closeSubpath()
    return r
}

func capRegion() -> CGPath {
    let r = CGMutablePath()
    r.move(to: p(0.44, 0.662))
    r.addCurve(to: p(0.668, 0.676), control1: p(0.52, 0.655), control2: p(0.60, 0.658))
    r.addLine(to: p(0.70, 0.85))
    r.addLine(to: p(0.44, 0.85))
    r.closeSubpath()
    return r
}

func napeRegion(simple: Bool) -> CGPath {
    let low: CGFloat = simple ? 0.53 : 0.55
    let r = CGMutablePath()
    r.move(to: p(0.44, 0.665))
    r.addCurve(to: p(0.555, 0.660), control1: p(0.48, 0.662), control2: p(0.52, 0.660))
    r.addCurve(to: p(0.510, low), control1: p(0.590, 0.625), control2: p(0.560, 0.560))
    r.addCurve(to: p(0.44, low - 0.01), control1: p(0.49, low - 0.008), control2: p(0.46, low - 0.01))
    r.closeSubpath()
    return r
}

// The white of the back and breast: everything above a line that runs level
// along the side from the black rump, then drops to the waterline in front of
// the breast; below it the flanks stay black.
func whiteRegion() -> CGPath {
    let r = CGMutablePath()
    r.move(to: p(0.215, 0.60))
    r.addLine(to: p(0.215, 0.44))
    r.addCurve(to: p(0.645, waterline), control1: p(0.38, 0.385), control2: p(0.60, 0.39))
    r.addLine(to: p(0.90, waterline))
    r.addLine(to: p(0.90, 0.60))
    r.closeSubpath()
    return r
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(color)
    ctx.fillPath()
}

func fillClipped(_ ctx: CGContext, _ clip: CGPath, _ path: CGPath, _ color: CGColor) {
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    fill(ctx, path, color)
    ctx.restoreGState()
}

func fillGradient(
    _ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from a: CGPoint, to b: CGPoint
) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

let ink = rgb(0x16181F)
let plumage = gradient([(0, rgb(0xFFFFFF)), (1, rgb(0xE4ECF1))])
let billColor = gradient([(0, rgb(0xF4DE84)), (1, rgb(0xC9B455))])
let napeColor = rgb(0x8ED6B0)

func drawDuck(_ ctx: CGContext, simple: Bool, px: CGFloat) {
    let body = duckBody()
    let head = duckHead()

    // Soft depth: one shadow under the whole silhouette.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -px * 0.010), blur: px * (simple ? 0.02 : 0.035),
        color: rgb(0x031225, 0.55))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    fill(ctx, body, ink)
    fill(ctx, head, ink)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // Back and breast white, flanks and rump black (lit a little from above).
    fillGradient(
        ctx, body, gradient([(0, rgb(0x2E3340)), (1, rgb(0x111318))]),
        from: p(0, 0.47), to: p(0, waterline))
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    fillGradient(ctx, whiteRegion(), plumage, from: p(0, 0.78), to: p(0, 0.28))
    ctx.restoreGState()

    // Head and neck white, then the cap, the nape and the bill.
    fillGradient(ctx, head, plumage, from: p(0, 0.78), to: p(0, 0.28))
    fillClipped(ctx, head, capRegion(), ink)
    fillClipped(ctx, head, napeRegion(simple: simple), napeColor)
    ctx.saveGState()
    ctx.addPath(head)
    ctx.clip()
    fillGradient(ctx, billRegion(), billColor, from: p(0.70, 0.76), to: p(0.86, 0.58))
    ctx.restoreGState()

    if simple { return }

    // Eye at the lower edge of the cap, with a catch-light.
    let eye = CGRect(x: 0.602, y: 0.648, width: 0.028, height: 0.028)
    fill(ctx, CGPath(ellipseIn: eye.insetBy(dx: -0.005, dy: -0.005), transform: nil), rgb(0xFFFFFF, 0.85))
    fill(ctx, CGPath(ellipseIn: eye, transform: nil), rgb(0x0B0C10))
    fill(ctx, CGPath(ellipseIn: CGRect(x: 0.617, y: 0.664, width: 0.008, height: 0.008), transform: nil), rgb(0xFFFFFF))

    // Glassy sheen on the crown and along the back.
    let sheen = gradient([(0, rgb(0xFFFFFF, 0.30)), (1, rgb(0xFFFFFF, 0))])
    ctx.saveGState()
    ctx.addPath(head)
    ctx.clip()
    ctx.drawRadialGradient(
        sheen, startCenter: p(0.55, 0.745), startRadius: 0, endCenter: p(0.55, 0.745),
        endRadius: 0.06, options: [])
    ctx.restoreGState()
}

// MARK: - Scene

func drawScene(_ ctx: CGContext, simple: Bool, px: CGFloat) {
    // Dawn sky over a deep sea. At small sizes the pale dawn band would sit
    // right behind the white head, so the sky stays blue there.
    let sky = simple
        ? gradient([(0, rgb(0x0F2A5E)), (1, rgb(0x3F7FBD))])
        : gradient([
            (0, rgb(0x0B2152)), (0.42, rgb(0x2A62A4)), (0.76, rgb(0xE8968A)), (1, rgb(0xFFD7A2)),
        ])
    ctx.drawLinearGradient(sky, start: p(0, 1), end: p(0, horizon), options: [])
    let seaRect = CGRect(x: 0, y: 0, width: 1, height: horizon)
    let sea = gradient([(0, rgb(0x5FA8B6)), (0.35, rgb(0x1E6A86)), (1, rgb(0x08294A))])
    ctx.saveGState()
    ctx.clip(to: seaRect)
    ctx.drawLinearGradient(sea, start: p(0, horizon), end: p(0, 0), options: [])
    ctx.restoreGState()

    if !simple {
        // The sun: an app tile half risen from the sea, with a halo.
        let sunRect = CGRect(x: 0.14, y: horizon - 0.075, width: 0.19, height: 0.19)
        let halo = gradient([(0, rgb(0xFFE7B8, 0.75)), (1, rgb(0xFFE7B8, 0))])
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: horizon, width: 1, height: 1))
        ctx.drawRadialGradient(
            halo, startCenter: p(sunRect.midX, sunRect.midY), startRadius: 0.06,
            endCenter: p(sunRect.midX, sunRect.midY), endRadius: 0.26, options: [])
        let sun = squircle(sunRect, radius: sunRect.width * 0.225)
        fillGradient(
            ctx, sun, gradient([(0, rgb(0xFFFBEA)), (0.55, rgb(0xFFD58A)), (1, rgb(0xFF9F5A))]),
            from: p(0, sunRect.maxY), to: p(0, horizon))
        // Glass edge on the tile.
        ctx.addPath(sun)
        ctx.setLineWidth(0.006)
        ctx.setStrokeColor(rgb(0xFFFFFF, 0.8))
        ctx.strokePath()
        ctx.restoreGState()

        // Its glitter on the water, and a few ripples.
        ctx.saveGState()
        ctx.clip(to: seaRect)
        let glitter = gradient([(0, rgb(0xFFD9A8, 0.55)), (1, rgb(0xFFD9A8, 0))])
        ctx.drawLinearGradient(
            glitter, start: p(0, horizon), end: p(0, horizon - 0.16), options: [])
        ctx.restoreGState()
        ctx.setLineCap(.round)
        let ripples: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.06, 0.44, 0.12, 0.35), (0.80, 0.43, 0.10, 0.35),
            (0.09, 0.17, 0.16, 0.22), (0.62, 0.13, 0.22, 0.20), (0.30, 0.07, 0.14, 0.14),
        ]
        for (x, y, w, alpha) in ripples {
            ctx.setStrokeColor(rgb(0xFFFFFF, alpha))
            ctx.setLineWidth(0.012)
            ctx.move(to: p(x, y))
            ctx.addLine(to: p(x + w, y))
            ctx.strokePath()
        }
        // The duck's shadow on the water.
        let shade = gradient([(0, rgb(0x041A30, 0.45)), (1, rgb(0x041A30, 0))])
        ctx.saveGState()
        ctx.translateBy(x: 0.43, y: waterline - 0.005)
        ctx.scaleBy(x: 1, y: 0.16)
        ctx.drawRadialGradient(
            shade, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 0.40,
            options: [])
        ctx.restoreGState()
    }

    // The duck. Small sizes draw it larger and centred, the 16 px one most
    // (it fills the tile from tail to bill tip there).
    ctx.saveGState()
    if simple {
        let grow: CGFloat = px < 20 ? 1.22 : 1.14
        ctx.translateBy(x: 0.50, y: 0.46)
        ctx.scaleBy(x: grow, y: grow)
        ctx.translateBy(x: -0.47, y: -0.50)
    }
    drawDuck(ctx, simple: simple, px: px)
    ctx.restoreGState()

    // Waterline: a bright edge where the bird meets the sea.
    if !simple {
        ctx.setStrokeColor(rgb(0xDDF3F7, 0.7))
        ctx.setLineWidth(0.010)
        ctx.setLineCap(.round)
        ctx.move(to: p(0.13, waterline))
        ctx.addLine(to: p(0.72, waterline))
        ctx.strokePath()
    }
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let simple = size <= 32

    // macOS icon grid: an 824 pt body centred on the 1024 pt canvas, corner
    // radius 185.4 pt, with the system's soft drop shadow below it.
    let tile = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let tilePath = squircle(tile, radius: s * 185.4 / 1024)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 22 / 1024,
        color: rgb(0x000000, 0.32))
    fill(ctx, tilePath, rgb(0x16305F))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.translateBy(x: tile.minX, y: tile.minY)
    ctx.scaleBy(x: tile.width, y: tile.height)
    drawScene(ctx, simple: simple, px: tile.width)

    // Liquid Glass: light from above, a specular sweep and a lit rim.
    let gloss = gradient([(0, rgb(0xFFFFFF, 0.14)), (1, rgb(0xFFFFFF, 0))])
    ctx.drawLinearGradient(gloss, start: p(0, 1), end: p(0, 0.62), options: [])
    ctx.restoreGState()

    if !simple {
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.setLineWidth(s * 6 / 1024)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rim = gradient([
            (0, rgb(0xFFFFFF, 0.55)), (0.5, rgb(0xFFFFFF, 0.10)), (1, rgb(0xFFFFFF, 0.25)),
        ])
        ctx.drawLinearGradient(rim, start: p(0, tile.maxY), end: p(0, tile.minY), options: [])
        ctx.restoreGState()
    }

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
