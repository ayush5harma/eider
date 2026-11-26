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
// folded from paper and set on black, the way Apple's black-background icons
// hold one self-contained object with an even margin (the owner's ask of
// 2026-11-26, after 0.1.5's full-bleed "Wedge" on plum). The bill is a wedge
// running diagonally from its back at the top left to its tip at the bottom
// right; the lobe is a flap folded up off the bill's top edge (the culmen)
// and the nape a flap folded down off its lower edge (the gape), so the three
// share edges and read as one piece. Each part is split along a crease into
// a plane facing the light (top left) and a plane in shadow, the origami
// look of the reference. The colours stay the owner's "Sunset": orange-to-
// pink bill, gold lobe, violet nape, a touch deeper in the Dark appearance.
// No eye, no head outline: a mark first, a bill second. (0.1.0 drew a
// feather, 0.1.3 a whole drake.) Six facet layers in three glass groups, so
// the bill casts its shadow over both flaps; the system supplies the glass.
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

func poly(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    path.addLines(between: points)
    path.closeSubpath()
    return path
}

// MARK: - Palette ("Sunset", a lit and a shadow plane per part, on black)

// A two-stop linear gradient. start/stop are in the unit square with y DOWN,
// Icon Composer's convention, so the same values feed icon.json and the icns.
struct Fill {
    var from: UInt32
    var to: UInt32
    var start = p(0.5, 0)
    var stop = p(0.5, 1)
}

// Dark fills are the light ones at 88% brightness, so the hues sit in the
// Dark appearance without glowing.
func dimmed(_ hex: UInt32) -> UInt32 {
    [16, 8, 0].reduce(0) { acc, shift in acc | UInt32((CGFloat((hex >> shift) & 0xFF) * 0.88).rounded()) << shift }
}

func dimmed(_ f: Fill) -> Fill { Fill(from: dimmed(f.from), to: dimmed(f.to), start: f.start, stop: f.stop) }

let billLit = Fill(from: 0xFFAE4A, to: 0xFF7A52, start: p(0, 0.3), stop: p(1, 0.7))
let billShade = Fill(from: 0xFF5C80, to: 0xD82C6C, start: p(0, 0.3), stop: p(1, 0.7))
let lobeLit = Fill(from: 0xFFF3A6, to: 0xFFE070)
let lobeShade = Fill(from: 0xFFCB3D, to: 0xF2A619)
let napeLit = Fill(from: 0xC7A6FF, to: 0xA27BFF, start: p(0, 0), stop: p(1, 1))
let napeShade = Fill(from: 0x7F55EE, to: 0x5A2FD0, start: p(0, 0), stop: p(1, 1))
// Near-black, a little lifted at the top so the glass rim still reads.
let ground = Fill(from: 0x1C1C1F, to: 0x000000, start: p(0.5, 0), stop: p(0.5, 0.7))
let groundDark = Fill(from: 0x141416, to: 0x000000, start: p(0.5, 0), stop: p(0.5, 0.7))

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

// A folded part: its outline, the crease between two of its vertices, and
// which side of the crease faces the light.
struct Part {
    var name: String
    var outline: [CGPoint]
    var crease: (Int, Int)
    var litIsFirstHalf: Bool // the half running from crease.0 to crease.1
    var lit: Fill
    var shade: Fill
}

// The outline cut along the chord i-j: (i ... j, j ... i).
func halves(_ outline: [CGPoint], _ i: Int, _ j: Int) -> ([CGPoint], [CGPoint]) {
    func walk(_ from: Int, _ to: Int) -> [CGPoint] {
        var points = [outline[from]]
        var k = from
        while k != to {
            k = (k + 1) % outline.count
            points.append(outline[k])
        }
        return points
    }
    return (walk(i, j), walk(j, i))
}

// The object's bounds take this share of the canvas, centred: 82% of the
// tile, the even margin of the reference.
let span: CGFloat = 0.82
// Outer corners are rounded to this (before fitting); creases stay sharp.
let cornerRadius: CGFloat = 20

func mark() -> [Group] {
    let tip = p(890, 200), gapeEnd = p(120, 600), culmenEnd = p(480, 920), ridgeEnd = p(300, 760)
    let parts = [
        Part(
            name: "nape", outline: [gapeEnd, lerp(gapeEnd, tip, 0.5), p(330, 110), p(110, 300)],
            crease: (0, 2), litIsFirstHalf: false, lit: napeLit, shade: napeShade),
        Part(
            name: "lobe", outline: [culmenEnd, p(800, 920), p(910, 720), lerp(culmenEnd, tip, 0.5)],
            crease: (0, 2), litIsFirstHalf: true, lit: lobeLit, shade: lobeShade),
        Part(
            name: "bill", outline: [culmenEnd, tip, gapeEnd, ridgeEnd],
            crease: (1, 3), litIsFirstHalf: false, lit: billLit, shade: billShade),
    ]

    let all = parts.flatMap(\.outline)
    let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
    let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
    let scale = canvas * span / max(maxX - minX, maxY - minY)
    func fit(_ q: CGPoint) -> CGPoint {
        p(canvas / 2 + (q.x - (minX + maxX) / 2) * scale, canvas / 2 + (q.y - (minY + maxY) / 2) * scale)
    }
    let fitted = parts.map { part -> Part in
        var moved = part
        moved.outline = part.outline.map(fit)
        return moved
    }
    // Round the outside of the whole object once, so the shared edges and
    // creases inside it stay crisp.
    let silhouette = roundConvex(
        fitted.dropFirst().reduce(poly(fitted[0].outline)) { $0.union(poly($1.outline)) }, cornerRadius * scale)

    // Back to front: nape, lobe, bill; each part its own glass group.
    return fitted.map { part in
        let (first, second) = halves(part.outline, part.crease.0, part.crease.1)
        let (litHalf, shadeHalf) = part.litIsFirstHalf ? (first, second) : (second, first)
        func facet(_ suffix: String, _ points: [CGPoint], _ fill: Fill) -> Layer {
            Layer(name: "\(part.name)-\(suffix)", path: poly(points).intersection(silhouette), fill: fill, dark: dimmed(fill))
        }
        return Group(layers: [facet("shade", shadeHalf, part.shade), facet("lit", litHalf, part.lit)], translucency: 0.3)
    }
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
            ["value": gradientValue(ground)],
            ["appearance": "dark", "value": gradientValue(groundDark)],
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
    ctx.setFillColor(rgb(ground.to))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    fillGradient(ctx, ground, over: tile)

    // The layers were drawn for the full canvas, which the system maps onto the tile.
    ctx.translateBy(x: tile.minX, y: tile.minY)
    ctx.scaleBy(x: tile.width / canvas, y: tile.height / canvas)
    let px = canvas / tile.width // one device pixel, in canvas units

    for group in groups {
        // Each glass group casts its neutral shadow as one silhouette.
        let silhouette = group.layers.dropFirst().reduce(group.layers[0].path) { $0.union($1.path) }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 26 / 1024, color: rgb(0, 0.6))
        ctx.addPath(silhouette)
        ctx.setFillColor(rgb(ground.to))
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
                    gradient([(0, rgb(0xFFFFFF, 0.6)), (0.5, rgb(0xFFFFFF, 0.08)), (1, rgb(0xFFFFFF, 0.2))]),
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
        gradient([(0, rgb(0xFFFFFF, 0.08)), (1, rgb(0xFFFFFF, 0))]),
        start: p(0, tile.maxY), end: p(0, tile.midY + tile.height * 0.12), options: [])
    ctx.restoreGState()
    // On black the rim is what separates the tile from a dark Dock, so it is
    // kept (at least a pixel wide) at the small sizes too.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setLineWidth(max(s * 6 / 1024, 1))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(0xFFFFFF, small ? 0.3 : 0.4)), (0.5, rgb(0xFFFFFF, 0.1)), (1, rgb(0xFFFFFF, 0.22))]),
        start: p(0, tile.maxY), end: p(0, tile.minY), options: [])
    ctx.restoreGState()
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
