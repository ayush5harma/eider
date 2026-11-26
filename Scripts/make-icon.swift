// Draws Eider's app icon from original geometry (CoreGraphics only, no SF
// Symbols, no third-party artwork) and writes it twice:
//   Resources/AppIcon.icon  Icon Composer bundle (icon.json + one SVG per
//                           layer); actool compiles it into Assets.car so
//                           macOS 26+ applies Liquid Glass and the Default,
//                           Dark, Clear and Tinted appearances itself.
//   Resources/AppIcon.icns  the same artwork flattened, with the glass look
//                           approximated, for macOS 14/15 and Xcode-less builds.
// Usage:
//   swift Scripts/make-icon.swift Resources
//
// The picture is an abstract mark taken from the drake common eider's bill,
// full bleed in the squircle: the bill as one amber wedge sweeping from the
// top-left corner to a rounded tip near the bottom-right, its top line
// (culmen) dead straight as the eider's forehead-to-tip line is; the pale
// lobe the bill sends up into the forehead as a lime leaf crossing that line;
// the black cap as the ink ground; the sea-green nape as the plane below, with
// a sliver of ink between it and the bill where the bill closes. No eye, no
// head outline: a mark first, a bill second. (0.1.0 drew a feather and 0.1.3
// a whole drake; both were dropped for this.) Three layers in two glass
// groups; the system supplies the depth.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let canvas: CGFloat = 1024

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { p(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t) }

func stroked(_ path: CGPath, _ width: CGFloat) -> CGPath {
    path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

// Morphological opening: rounds every convex corner sharper than r to radius r
// and leaves gentler curves alone.
func roundConvex(_ path: CGPath, _ r: CGFloat) -> CGPath {
    let eroded = path.subtracting(stroked(path, 2 * r))
    return eroded.union(stroked(eroded, 2 * r))
}

// Shapes run off the canvas on purpose (full bleed); clip them to a margin
// box so the SVGs stay small. The system clips to the squircle anyway.
let bleed = CGPath(rect: CGRect(x: -40, y: -40, width: 1104, height: 1104), transform: nil)

// MARK: - Palette (the drake's head, pushed vivid)

// A two-stop linear gradient. start/stop are in the unit square with y DOWN,
// Icon Composer's convention, so the same values feed icon.json and the icns.
struct Fill {
    var from: UInt32
    var to: UInt32
    var start = p(0.5, 0)
    var stop = p(0.5, 1)
}

let amber = Fill(from: 0xFFE27A, to: 0xFF9F1C, start: p(0.2, 0.1), stop: p(0.9, 0.8))
let amberDark = Fill(from: 0xFFD55C, to: 0xF08A12, start: p(0.2, 0.1), stop: p(0.9, 0.8))
let lime = Fill(from: 0xEEFF9A, to: 0xA8E04A)
let sea = Fill(from: 0x7FF2D2, to: 0x14A8A0, start: p(0.2, 0), stop: p(0.8, 1))
let seaDark = Fill(from: 0x52D9BC, to: 0x0E7F86, start: p(0.2, 0), stop: p(0.8, 1))
let ink = Fill(from: 0x24345C, to: 0x0B1226, start: p(0.3, 0), stop: p(0.7, 1))
let inkDark = Fill(from: 0x141C30, to: 0x05080F, start: p(0.3, 0), stop: p(0.7, 1))

// MARK: - The mark, in the 1024 pt layer canvas (y up; the system maps it onto the squircle)

struct Layer {
    var name: String
    var path: CGPath
    var fill: Fill
    var dark: Fill
    var opacity: CGFloat = 1
}

struct Group {
    var layers: [Layer] // back to front
    var translucency: Double
}

// A wedge from off the left edge to a rounded tip: straight culmen from a to
// the tip, gape from the tip back to b, bowed by `bow` at its middle (positive
// bows it up into the wedge), the tip rounded to `tipRound`.
func bill(culmenFrom a: CGPoint, tip t: CGPoint, gapeFrom b: CGPoint, bow: CGFloat, tipRound: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: a)
    path.addLine(to: t)
    let mid = lerp(t, b, 0.5)
    let dx = b.x - t.x, dy = b.y - t.y, len = (dx * dx + dy * dy).squareRoot()
    path.addQuadCurve(to: b, control: p(mid.x + dy / len * bow, mid.y - dx / len * bow))
    path.closeSubpath()
    return roundConvex(path, tipRound).intersection(bleed)
}

func mark() -> [Group] {
    let billPath = bill(culmenFrom: p(-200, 1190), tip: p(960, 300), gapeFrom: p(-200, 400), bow: 30, tipRound: 70)

    // The lobe: a long leaf that starts inside the bill and climbs across the
    // culmen off the top edge.
    let lobe = CGMutablePath()
    lobe.move(to: p(560, 470))
    lobe.addQuadCurve(to: p(250, 1180), control: p(640, 900))
    lobe.addLine(to: p(-40, 1180))
    lobe.addQuadCurve(to: p(560, 470), control: p(180, 680))
    lobe.closeSubpath()

    // The nape: its top edge runs just under the gape, leaving a sliver of
    // ink between them that widens towards the tip.
    let nape = CGMutablePath()
    nape.move(to: p(-120, -120))
    nape.addLine(to: p(-120, 340))
    nape.addCurve(to: p(1180, 110), control1: p(300, 250), control2: p(800, 150))
    nape.addLine(to: p(1180, -120))
    nape.closeSubpath()

    return [
        Group(layers: [
            Layer(name: "nape", path: nape.intersection(bleed), fill: sea, dark: seaDark),
        ], translucency: 0.3),
        Group(layers: [
            Layer(name: "bill", path: billPath, fill: amber, dark: amberDark),
            Layer(name: "lobe", path: roundConvex(lobe, 60).intersection(bleed), fill: lime, dark: lime, opacity: 0.8),
        ], translucency: 0.35),
    ]
}

// MARK: - Icon Composer bundle

func svgPathData(_ path: CGPath) -> String {
    var out = ""
    func q(_ pt: CGPoint) -> String { String(format: "%.2f %.2f", pt.x, canvas - pt.y) }
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: out += "M\(q(e.points[0]))"
        case .addLineToPoint: out += "L\(q(e.points[0]))"
        case .addQuadCurveToPoint: out += "Q\(q(e.points[0])) \(q(e.points[1]))"
        case .addCurveToPoint: out += "C\(q(e.points[0])) \(q(e.points[1])) \(q(e.points[2]))"
        case .closeSubpath: out += "Z"
        @unknown default: break
        }
    }
    return out
}

func iconColor(_ hex: UInt32) -> String {
    let parts = [(hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF].map { String(format: "%.5f", Double($0) / 255) }
    return "srgb:\(parts.joined(separator: ",")),1.00000"
}

func gradientValue(_ f: Fill) -> [String: Any] {
    [
        "linear-gradient": [iconColor(f.from), iconColor(f.to)],
        "orientation": ["start": ["x": f.start.x, "y": f.start.y], "stop": ["x": f.stop.x, "y": f.stop.y]],
    ]
}

func writeIconBundle(_ groups: [Group], to bundle: URL) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: bundle)
    let assets = bundle.appendingPathComponent("Assets")
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    for layer in groups.flatMap(\.layers) {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\
            <path fill="#\(String(format: "%06X", layer.fill.from))" fill-rule="nonzero" d="\(svgPathData(layer.path))"/></svg>

            """
        try svg.write(to: assets.appendingPathComponent("\(layer.name).svg"), atomically: true, encoding: .utf8)
    }
    func layerJSON(_ l: Layer) -> [String: Any] {
        var json: [String: Any] = [
            "name": l.name, "image-name": "\(l.name).svg", "glass": true,
            "fill-specializations": [
                ["value": gradientValue(l.fill)],
                ["appearance": "dark", "value": gradientValue(l.dark)],
            ],
        ]
        if l.opacity < 1 { json["opacity"] = l.opacity }
        return json
    }
    // Icon Composer lists groups and layers front first.
    let json: [String: Any] = [
        "fill-specializations": [
            ["value": gradientValue(ink)],
            ["appearance": "dark", "value": gradientValue(inkDark)],
        ],
        "groups": groups.reversed().map { g in
            [
                "layers": g.layers.reversed().map(layerJSON),
                "shadow": ["kind": "neutral", "opacity": 0.5],
                "translucency": ["enabled": true, "value": g.translucency],
            ] as [String: Any]
        },
        "supported-platforms": ["squares": ["macOS"]],
    ]
    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: bundle.appendingPathComponent("icon.json"))
}

// MARK: - Flattened icns

// Apple's continuous-corner rounded rectangle (the "squircle"): each corner
// is three cubic segments that start 1.52866 r along the edge, so curvature
// ramps up instead of jumping as it does on a circular-arc corner.
func squircle(_ rect: CGRect, radius r: CGFloat) -> CGPath {
    let corner: [(CGPoint, CGPoint, CGPoint)] = [
        (p(1.08849, 0), p(0.86840, 0), p(0.66993, 0.06480)),
        (p(0.37282, 0.16906), p(0.16906, 0.37282), p(0.06480, 0.66993)),
        (p(0, 0.86840), p(0, 1.08849), p(0, 1.52866)),
    ]
    let frames: [(CGPoint, CGVector, CGVector)] = [
        (p(rect.maxX, rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        (p(rect.maxX, rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
        (p(rect.minX, rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
        (p(rect.minX, rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
    ]
    let path = CGMutablePath()
    for (index, (origin, back, down)) in frames.enumerated() {
        func map(_ q: CGPoint) -> CGPoint {
            p(origin.x + (back.dx * q.x + down.dx * q.y) * r, origin.y + (back.dy * q.x + down.dy * q.y) * r)
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

// Fills the current clip with f laid across box (y up), the way Icon
// Composer lays a layer's gradient across that layer's bounds.
func fillGradient(_ ctx: CGContext, _ f: Fill, over box: CGRect) {
    func at(_ u: CGPoint) -> CGPoint { p(box.minX + u.x * box.width, box.maxY - u.y * box.height) }
    ctx.drawLinearGradient(
        gradient([(0, rgb(f.from)), (1, rgb(f.to))]), start: at(f.start), end: at(f.stop),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func render(_ groups: [Group], size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let small = size <= 32

    // macOS grid: an 824 pt body centred on the 1024 pt canvas, corner radius
    // 185.4 pt, with the system's soft drop shadow below it.
    let tile = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let tilePath = squircle(tile, radius: s * 185.4 / 1024)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 22 / 1024, color: rgb(0, 0.32))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(ink.to))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    fillGradient(ctx, ink, over: tile)

    // The layers were drawn for the full canvas, which the system maps onto the tile.
    ctx.translateBy(x: tile.minX, y: tile.minY)
    ctx.scaleBy(x: tile.width / canvas, y: tile.height / canvas)
    let px = canvas / tile.width // one device pixel, in canvas units

    for group in groups {
        // Each glass group casts its neutral shadow as one silhouette.
        let silhouette = group.layers.dropFirst().reduce(group.layers[0].path) { $0.union($1.path) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 26 / 1024, color: rgb(0x050A18, 0.4))
        ctx.addPath(silhouette)
        ctx.setFillColor(rgb(ink.to))
        ctx.fillPath()
        ctx.restoreGState()

        for layer in group.layers {
            let box = layer.path.boundingBoxOfPath
            ctx.saveGState()
            ctx.setAlpha(layer.opacity)
            ctx.addPath(layer.path)
            ctx.clip()
            fillGradient(ctx, layer.fill, over: box)
            // Specular rim along each glass layer's edge, bright at the top.
            if !small {
                ctx.addPath(layer.path)
                ctx.setLineWidth(4 * max(px, 1))
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                ctx.drawLinearGradient(
                    gradient([(0, rgb(0xFFFFFF, 0.7)), (0.5, rgb(0xFFFFFF, 0.1)), (1, rgb(0xFFFFFF, 0.25))]),
                    start: p(0, box.maxY), end: p(0, box.minY), options: [])
            }
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()

    // Light from above across the tile, and its lit rim.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xFFFFFF, 0.12)), (1, rgb(0xFFFFFF, 0))]),
        start: p(0, tile.maxY), end: p(0, tile.midY + tile.height * 0.12), options: [])
    ctx.restoreGState()
    if !small {
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.setLineWidth(s * 6 / 1024)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, rgb(0xFFFFFF, 0.45)), (0.5, rgb(0xFFFFFF, 0.08)), (1, rgb(0xFFFFFF, 0.2))]),
            start: p(0, tile.maxY), end: p(0, tile.minY), options: [])
        ctx.restoreGState()
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fputs("could not write \(url.path)\n", stderr)
        exit(1)
    }
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    fputs("usage: swift make-icon.swift <Resources directory>\n", stderr)
    exit(2)
}
let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let groups = mark()
try writeIconBundle(groups, to: resources.appendingPathComponent("AppIcon.icon"))

let work = FileManager.default.temporaryDirectory.appendingPathComponent("eider-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
for base in [16, 32, 128, 256, 512] {
    writePNG(render(groups, size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(groups, size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
