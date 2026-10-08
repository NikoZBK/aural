// Draws Aural's app icons: an EQ response shaped like an A on a graphite tile, following
// the macOS icon grid (an 824 pt tile with a 100 pt transparent margin on a 1024 pt canvas).
//
//   swift scripts/draw-icon.swift [output directory]   # default: Resources
//   bash scripts/make-icon.sh                          # then package the ICNS files
//
// The response is flat at 0 dB with one tall boost: its sides are the legs of the A, and
// the crossbar lies on the +6 dB grid line. AppIcon is the idle icon and the Finder icon;
// AppIconActive shows while EQ is processing: the same A, lit inside. (A node marker at the
// apex would read as Å.)
import CoreGraphics
import Foundation
import ImageIO

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185
// The response spans 20 Hz–20 kHz across the plot, with 0 dB low in the tile.
let plot = tile.insetBy(dx: 74, dy: 0)
let zeroDecibels: CGFloat = 290
let pixelsPerDecibel: CGFloat = 170 / 6
func level(_ decibels: CGFloat) -> CGFloat { zeroDecibels + decibels * pixelsPerDecibel }

// The letter: feet on the 0 dB line, apex at +16.6 dB, crossbar at +6 dB.
let apex = CGPoint(x: canvas / 2, y: 760)
let footSpread: CGFloat = 215
let leftFoot = CGPoint(x: apex.x - footSpread, y: level(0))
let rightFoot = CGPoint(x: apex.x + footSpread, y: level(0))
let crossbarY = level(6)
let crossbarHalfWidth = footSpread * (apex.y - crossbarY) / (apex.y - level(0))
let strokeWidth: CGFloat = 48

let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [red, green, blue, alpha])!
}
let graphite = color(0.11, 0.118, 0.129)
// AuralStyle.accent in dark appearance.
let accent = color(0.30, 0.74, 0.86)

/// The fraction of the plot's width for a frequency on a log scale.
func position(hertz: Double) -> CGFloat {
    CGFloat((log10(hertz) - log10(20)) / 3)
}

/// Flat, then one boost with straight sides: rounded where it leaves 0 dB like a
/// filter's skirt, and nearly sharp at the apex like the letter.
func response() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: plot.minX, y: level(0)))
    path.addArc(tangent1End: leftFoot, tangent2End: apex, radius: 70)
    path.addArc(tangent1End: apex, tangent2End: rightFoot, radius: 12)
    path.addArc(tangent1End: rightFoot, tangent2End: CGPoint(x: plot.maxX, y: level(0)), radius: 70)
    path.addLine(to: CGPoint(x: plot.maxX, y: level(0)))
    return path
}

func draw(active: Bool) -> CGImage {
    let context = CGContext(data: nil, width: Int(canvas), height: Int(canvas), bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let tilePath = CGPath(roundedRect: tile, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)

    // A soft drop shadow under a flat tile.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0, 0, 0, 0.32))
    context.addPath(tilePath)
    context.setFillColor(graphite)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    // Frequency grid: decades brighter than the lines between them.
    for decade in [10.0, 100, 1000, 10000] {
        for multiple in 1...9 {
            let hertz = decade * Double(multiple)
            guard hertz > 20, hertz < 20000 else { continue }
            let x = plot.minX + position(hertz: hertz) * plot.width
            context.setStrokeColor(color(1, 1, 1, multiple == 1 ? 0.10 : 0.025))
            context.setLineWidth(multiple == 1 ? 4 : 3)
            context.strokeLineSegments(between: [CGPoint(x: x, y: tile.minY), CGPoint(x: x, y: tile.maxY)])
        }
    }
    // Level grid every 6 dB, with 0 dB as the reference line.
    for decibels in stride(from: -6, through: 24, by: 6) {
        let y = level(CGFloat(decibels))
        context.setStrokeColor(color(1, 1, 1, decibels == 0 ? 0.16 : 0.06))
        context.setLineWidth(decibels == 0 ? 5 : 3)
        context.strokeLineSegments(between: [CGPoint(x: tile.minX, y: y), CGPoint(x: tile.maxX, y: y)])
    }

    let curve = response()
    if active {
        // Lit area between the boost and 0 dB.
        let area = curve.mutableCopy()!
        area.closeSubpath()
        context.addPath(area)
        context.setFillColor(color(0.30, 0.74, 0.86, 0.32))
        context.fillPath()
    }

    context.setStrokeColor(accent)
    context.setLineWidth(strokeWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(curve)
    context.strokePath()
    // The crossbar is the +6 dB grid line, drawn in the curve's color between the legs.
    context.strokeLineSegments(between: [CGPoint(x: apex.x - crossbarHalfWidth, y: crossbarY),
                                         CGPoint(x: apex.x + crossbarHalfWidth, y: crossbarY)])
    context.restoreGState()

    // A hairline edge keeps the tile's outline on dark Dock backgrounds.
    context.addPath(CGPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), cornerWidth: tileRadius - 1.5, cornerHeight: tileRadius - 1.5, transform: nil))
    context.setStrokeColor(color(1, 1, 1, 0.09))
    context.setLineWidth(3)
    context.strokePath()
    return context.makeImage()!
}

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources", isDirectory: true)
for (name, active) in [("AppIcon", false), ("AppIconActive", true)] {
    let url = directory.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, draw(active: active), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write \(url.path)") }
    print("Wrote \(url.path)")
}
