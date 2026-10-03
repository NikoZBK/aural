import SwiftUI

struct InterfaceLoadingPalette {
    let background: NSColor
    let surface: NSColor
    let block: NSColor
    let text: NSColor
    let border: NSColor

    init(_ environment: EnvironmentValues) {
        func native(_ color: Color) -> NSColor {
            let value = color.resolve(in: environment)
            return NSColor(srgbRed: CGFloat(value.red), green: CGFloat(value.green),
                           blue: CGFloat(value.blue), alpha: CGFloat(value.opacity))
        }
        background = native(AuralStyle.background)
        surface = native(AuralStyle.surface)
        block = native(AuralStyle.elevated)
        text = native(AuralStyle.secondary)
        border = native(AuralStyle.border)
    }
}

/// No fields, pickers, SwiftUI layout, or animation timers: paint immediately.
final class InterfaceLoadingView: NSView {
    private var mode = InterfaceMode.easy
    private var palette = InterfaceLoadingPalette(EnvironmentValues())
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func configure(mode: InterfaceMode, palette: InterfaceLoadingPalette) {
        self.mode = mode
        self.palette = palette
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Loading \(mode.label) controls")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        palette.background.setFill()
        bounds.fill()
        func block(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            palette.block.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: max(0, width), height: max(0, height)), xRadius: 5, yRadius: 5).fill()
        }
        func card(_ rect: NSRect, rows: Int) {
            palette.surface.setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            path.fill()
            palette.border.setStroke()
            path.stroke()
            block(rect.minX + 16, rect.minY + 18, min(110, rect.width - 32), 10)
            for row in 0..<rows {
                let y = rect.minY + 50 + CGFloat(row) * 38
                if y + 18 < rect.maxY - 12 { block(rect.minX + 16, y, rect.width - 32, 18) }
            }
        }
        let width = bounds.width, height = bounds.height
        if mode == .professional {
            card(NSRect(x: 10, y: 52, width: 164, height: max(0, height - 66)), rows: 12)
            card(NSRect(x: width - 208, y: 52, width: 198, height: max(0, height - 66)), rows: 12)
            let center = max(0, width - 430)
            card(NSRect(x: 198, y: 52, width: center, height: min(246, height * 0.36)), rows: 3)
            card(NSRect(x: 198, y: min(246, height * 0.36) + 68, width: center,
                        height: max(0, height - min(246, height * 0.36) - 82)), rows: 12)
        } else {
            let left = min(360, max(260, (width - 48) * 0.26))
            card(NSRect(x: 24, y: 90, width: left, height: max(0, height - 114)), rows: 12)
            let rightX = left + 44, rightWidth = max(0, width - rightX - 24)
            let columns: CGFloat = rightWidth >= 700 ? 2 : 1
            let cardWidth = (rightWidth - (columns - 1) * 18) / columns
            for index in 0..<4 {
                let row = CGFloat(index / Int(columns)), column = CGFloat(index % Int(columns))
                let y = 90 + row * 240
                if y < height - 24 {
                    card(NSRect(x: rightX + column * (cardWidth + 18), y: y, width: cardWidth,
                                height: min(222, height - y - 24)), rows: 4)
                }
            }
        }
        NSString(string: "Loading \(mode.label) controls…").draw(at: NSPoint(x: 24, y: 18),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: palette.text])
    }
}
