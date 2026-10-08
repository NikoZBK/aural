// Draws Aural's app icons: an EQ response on a graphite tile, following the macOS
// icon grid (an 824 pt tile with a 100 pt transparent margin on a 1024 pt canvas).
//
//   swift scripts/draw-icon.swift [output directory]   # default: Resources
//   bash scripts/make-icon.sh                          # then package the ICNS files
//
// AppIcon is the idle icon and the Finder icon: the curve alone. AppIconActive shows
// while EQ is processing: the same curve, lit underneath, with its filter nodes.
import CoreGraphics
import Foundation
import ImageIO

let canvas: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185
// The response spans 20 Hz–20 kHz and ±12 dB, drawn inside the tile.
let plot = tile.insetBy(dx: 74, dy: 150)
let decibelRange: CGFloat = 12

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

/// A low shelf, a narrow presence dip, and an air bell, with flat response between
/// them: the shape of a headphone correction rather than a wave.
enum Band { case lowShelf, bell }
let bands: [(kind: Band, center: CGFloat, gain: CGFloat, width: CGFloat)] = [
    (.lowShelf, position(hertz: 110), 5.5, 0.07),
    (.bell, position(hertz: 2300), -6, 0.085),
    (.bell, position(hertz: 9500), 4.5, 0.065),
]
func gain(at fraction: CGFloat) -> CGFloat {
    bands.reduce(0) { sum, band in
        let distance = (fraction - band.center) / band.width
        switch band.kind {
        case .lowShelf: return sum + band.gain / (1 + exp(distance * 2.2))
        case .bell: return sum + band.gain * exp(-distance * distance / 2)
        }
    }
}
func point(at fraction: CGFloat) -> CGPoint {
    CGPoint(x: plot.minX + fraction * plot.width, y: plot.midY + gain(at: fraction) / decibelRange * plot.height / 2)
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
    for decibels in stride(from: -18, through: 18, by: 6) {
        let y = plot.midY + CGFloat(decibels) / decibelRange * plot.height / 2
        context.setStrokeColor(color(1, 1, 1, decibels == 0 ? 0.16 : 0.06))
        context.setLineWidth(decibels == 0 ? 5 : 3)
        context.strokeLineSegments(between: [CGPoint(x: tile.minX, y: y), CGPoint(x: tile.maxX, y: y)])
    }

    let curve = CGMutablePath()
    let samples = 400
    for index in 0...samples {
        let next = point(at: CGFloat(index) / CGFloat(samples))
        if index == 0 { curve.move(to: next) } else { curve.addLine(to: next) }
    }

    if active {
        // Lit area between the response and 0 dB.
        let area = curve.mutableCopy()!
        area.addLine(to: CGPoint(x: plot.maxX, y: plot.midY))
        area.addLine(to: CGPoint(x: plot.minX, y: plot.midY))
        area.closeSubpath()
        context.addPath(area)
        context.setFillColor(color(0.30, 0.74, 0.86, 0.24))
        context.fillPath()
    }

    context.addPath(curve)
    context.setStrokeColor(accent)
    context.setLineWidth(38)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    if active {
        // One node per band, cut out of the curve like the graph's band handles.
        for band in bands {
            let center = point(at: band.center)
            context.setFillColor(graphite)
            context.fillEllipse(in: CGRect(x: center.x - 44, y: center.y - 44, width: 88, height: 88))
            context.setFillColor(accent)
            context.fillEllipse(in: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
        }
    }
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
