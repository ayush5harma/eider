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
// The picture is one glyph, as macOS 26 icons are: a drake common eider in
// profile, floating, on a sea-blue gradient. What makes it an eider and not
// any duck is kept and everything else is dropped: the white back and breast,
// black flanks and tail, black cap, sea-green nape, and above all the wedge
// head, where the forehead runs in one straight line out to the bill tip.
// Six flat layers in one glass group; the system supplies the depth.
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

func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil)
}

// MARK: - Palette

struct Paint {
    var hex: UInt32
    var top: UInt32 // flattened icns only: light from above
    var bottom: UInt32
}

let white = Paint(hex: 0xF4F6F9, top: 0xFFFFFF, bottom: 0xD3DCE7)
let black = Paint(hex: 0x22252D, top: 0x3B404B, bottom: 0x1C1E25)
let seaGreen = Paint(hex: 0x94DCC2, top: 0xB2EBD6, bottom: 0x7FCBB0)
let billYellow = Paint(hex: 0xE2C55E, top: 0xF0D77C, bottom: 0xCDAE45)
let backgroundLight: (UInt32, UInt32) = (0x7CCBEA, 0x2A6DB0)
let backgroundDark: (UInt32, UInt32) = (0x22364B, 0x0C1623)

// MARK: - The drake, in the 1024 pt icon canvas (y up)

// Upper tangent point on a circle for a line from the outside point t.
func upperTangent(c: CGPoint, r: CGFloat, from t: CGPoint) -> CGPoint {
    let dx = t.x - c.x, dy = t.y - c.y
    let a = atan2(dy, dx), b = acos(r / (dx * dx + dy * dy).squareRoot())
    return p(c.x + r * cos(a + b), c.y + r * sin(a + b))
}

struct Layer {
    var name: String
    var path: CGPath
    var paint: Paint
    var glass = true
}

func drake() -> [Layer] {
    let c = p(645, 625), r: CGFloat = 122
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { p(c.x + x * r, c.y + y * r) }

    // Head: the crown circle plus a wedge whose top edge is tangent to it, so
    // forehead and bill are one line.
    let tipTop = at(2.5, -0.55), tipBottom = at(2.44, -0.85)
    let t = upperTangent(c: c, r: r, from: tipTop)
    let chin = at(cos(-62 * .pi / 180), sin(-62 * .pi / 180))
    let wedge = CGMutablePath()
    wedge.move(to: c)
    wedge.addLine(to: t)
    wedge.addLine(to: tipTop)
    wedge.addQuadCurve(to: tipBottom, control: at(2.6, -0.69))
    wedge.addLine(to: chin)
    wedge.closeSubpath()

    let neck = CGMutablePath()
    neck.move(to: at(-0.98, -0.2))
    neck.addCurve(to: p(490, 505), control1: p(c.x - 1.05 * r, 560), control2: p(520, 520))
    neck.addLine(to: p(770, 470))
    neck.addCurve(to: at(0.55, -0.72), control1: p(745, 510), control2: p(c.x + 0.6 * r, 560))
    neck.closeSubpath()
    let head = circle(c, r).union(wedge).union(neck)

    // Floating body: a short raised tail, flat back, full breast.
    let body = CGMutablePath()
    body.move(to: p(165, 478))
    body.addCurve(to: p(430, 518), control1: p(250, 505), control2: p(340, 520))
    body.addLine(to: p(540, 515))
    body.addCurve(to: p(805, 410), control1: p(705, 515), control2: p(810, 480))
    body.addCurve(to: p(630, 285), control1: p(800, 320), control2: p(725, 285))
    body.addLine(to: p(365, 285))
    body.addCurve(to: p(165, 478), control1: p(260, 285), control2: p(190, 375))
    body.closeSubpath()

    // Bill: the far part of the wedge, its base bowed forward the way the
    // eider's feathering runs out onto the bill.
    let b1 = p(t.x + (tipTop.x - t.x) * 0.30, t.y + (tipTop.y - t.y) * 0.30)
    let b2 = p(b1.x, chin.y + (tipBottom.y - chin.y) * ((b1.x - chin.x) / (tipBottom.x - chin.x)))
    let billMask = CGMutablePath()
    billMask.move(to: b1)
    billMask.addCurve(to: b2, control1: p(b1.x + 0.3 * r, b1.y - 0.3 * r), control2: p(b2.x + 0.3 * r, b2.y + 0.22 * r))
    billMask.addLine(to: p(b2.x, b2.y - r))
    billMask.addLine(to: at(4, -2))
    billMask.addLine(to: at(4, 2))
    billMask.addLine(to: p(b1.x, b1.y + r))
    billMask.closeSubpath()

    // Cap: above a line from the back of the crown, over the eye, to the bill.
    let capMask = CGMutablePath()
    capMask.move(to: at(-1.4, 0.1))
    capMask.addCurve(to: p(b1.x - 0.02 * r, b1.y - 0.06 * r), control1: at(-0.3, 0.3), control2: at(0.45, 0.3))
    capMask.addLine(to: at(4, 3))
    capMask.addLine(to: at(-2, 3))
    capMask.closeSubpath()

    // Nape: a sea-green wash down the back of the head, under the cap.
    let napeMask = CGMutablePath()
    napeMask.move(to: at(-0.42, 0.6))
    napeMask.addCurve(to: at(-1.3, -0.85), control1: at(-0.3, -0.15), control2: at(-0.75, -0.6))
    napeMask.addLine(to: at(-2, 0.6))
    napeMask.closeSubpath()

    // Flanks and tail: black below a long S from the tail to under the breast.
    let flankMask = CGMutablePath()
    flankMask.move(to: p(150, 540))
    flankMask.addCurve(to: p(690, 250), control1: p(380, 470), control2: p(470, 300))
    flankMask.addLine(to: p(100, 200))
    flankMask.closeSubpath()

    let layers = [
        Layer(name: "body", path: body.union(head), paint: white),
        Layer(name: "flank", path: body.intersection(flankMask), paint: black),
        Layer(name: "nape", path: head.intersection(napeMask).subtracting(capMask), paint: seaGreen),
        Layer(name: "cap", path: head.intersection(capMask).subtracting(billMask), paint: black),
        Layer(name: "eye", path: circle(at(0.30, 0.06), 0.085 * r), paint: black, glass: false),
        Layer(name: "bill", path: head.intersection(billMask), paint: billYellow),
    ]
    // Centre the glyph on the canvas at 90%, leaving the margin Apple's grid keeps.
    let box = layers.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
    var place = CGAffineTransform(translationX: canvas / 2, y: canvas / 2).scaledBy(x: 0.9, y: 0.9)
        .translatedBy(x: -box.midX, y: -box.midY)
    return layers.map { layer in
        var moved = layer
        moved.path = layer.path.copy(using: &place)!
        return moved
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

func writeIconBundle(_ layers: [Layer], to bundle: URL) throws {
    let fm = FileManager.default
    try? fm.removeItem(at: bundle)
    let assets = bundle.appendingPathComponent("Assets")
    try fm.createDirectory(at: assets, withIntermediateDirectories: true)
    for layer in layers {
        let svg = """
            <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\
            <path fill="#\(String(format: "%06X", layer.paint.hex))" d="\(svgPathData(layer.path))"/></svg>

            """
        try svg.write(to: assets.appendingPathComponent("\(layer.name).svg"), atomically: true, encoding: .utf8)
    }
    func background(_ stops: (UInt32, UInt32)) -> [String: Any] {
        [
            "linear-gradient": [iconColor(stops.0), iconColor(stops.1)],
            "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
        ]
    }
    // Icon Composer lists layers front first.
    let json: [String: Any] = [
        "fill-specializations": [
            ["value": background(backgroundLight)],
            ["appearance": "dark", "value": background(backgroundDark)],
        ],
        "groups": [[
            "layers": layers.reversed().map { ["name": $0.name, "image-name": "\($0.name).svg", "glass": $0.glass] },
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.4],
        ]],
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

func render(_ layers: [Layer], size: Int) -> CGImage {
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
    ctx.setFillColor(rgb(backgroundLight.1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(0, rgb(backgroundLight.0)), (1, rgb(backgroundLight.1))]),
        start: p(0, tile.maxY), end: p(0, tile.minY), options: [])

    // The layers were drawn for the full canvas, which the system maps onto the tile.
    ctx.translateBy(x: tile.minX, y: tile.minY)
    ctx.scaleBy(x: tile.width / canvas, y: tile.height / canvas)
    let px = canvas / tile.width // one device pixel, in canvas units

    // The glass group's neutral shadow: the whole silhouette, soft, below.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 12 / 1024), blur: s * 28 / 1024, color: rgb(0x0A2340, 0.35))
    ctx.addPath(layers[0].path)
    ctx.setFillColor(rgb(white.hex))
    ctx.fillPath()
    ctx.restoreGState()

    for layer in layers {
        let box = layer.path.boundingBoxOfPath
        ctx.saveGState()
        ctx.addPath(layer.path)
        ctx.clip()
        ctx.drawLinearGradient(
            gradient([(0, rgb(layer.paint.top)), (1, rgb(layer.paint.bottom))]),
            start: p(0, box.maxY), end: p(0, box.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // Specular rim along each glass layer's edge, bright at the top.
        if layer.glass && !small {
            ctx.addPath(layer.path)
            ctx.setLineWidth(3 * max(px, 1))
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            ctx.drawLinearGradient(
                gradient([(0, rgb(0xFFFFFF, 0.65)), (0.5, rgb(0xFFFFFF, 0.08)), (1, rgb(0xFFFFFF, 0.2))]),
                start: p(0, box.maxY), end: p(0, box.minY), options: [])
        }
        ctx.restoreGState()
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
            gradient([(0, rgb(0xFFFFFF, 0.55)), (0.5, rgb(0xFFFFFF, 0.10)), (1, rgb(0xFFFFFF, 0.25))]),
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
let layers = drake()
try writeIconBundle(layers, to: resources.appendingPathComponent("AppIcon.icon"))

let work = FileManager.default.temporaryDirectory.appendingPathComponent("eider-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
for base in [16, 32, 128, 256, 512] {
    writePNG(render(layers, size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(layers, size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
exit(task.terminationStatus)
