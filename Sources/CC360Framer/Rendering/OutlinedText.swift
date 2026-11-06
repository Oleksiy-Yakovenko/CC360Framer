import AppKit
import CoreText

/// Outlined text for the captions and the location card. Drawn in two passes so the outline is clean: every line is first
/// STROKED (round joins and caps, line width twice the outline width) in the outline colour, then the glyphs are FILLED
/// on top, which hides the inner half of the stroke. What is left is an outer outline of exactly `outline` px, uniform
/// and without miter spikes or cuts into the letters. An optional soft shadow is applied once to the whole group.
enum OutlinedText {
    struct Line {
        var text: String
        var font: NSFont
        var fill: NSColor
    }
    enum Align { case left, center, right }
    struct Shadow { var color: NSColor; var blur: CGFloat }

    /// Typographic size of a line, rounded up to whole pixels.
    static func measure(_ line: Line) -> (width: CGFloat, height: CGFloat) {
        let ct = ctLine(line)
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let w = CTLineGetTypographicBounds(ct, &asc, &desc, &lead)
        return (ceil(CGFloat(w)), ceil(asc + desc + lead))
    }

    /// Bitmap size for the lines: the text block plus `pad` on every side plus room for the outline.
    static func bitmapSize(lines: [Line], gap: CGFloat, pad: CGFloat, outline: CGFloat) -> (w: Int, h: Int) {
        let m = lines.map(measure)
        let extra = pad + ceil(max(outline, 0))
        let w = (m.map(\.width).max() ?? 0) + 2 * extra
        let h = m.map(\.height).reduce(0, +) + gap * CGFloat(max(lines.count - 1, 0)) + 2 * extra
        return (Int(w), Int(h))
    }

    /// Renders the lines into a premultiplied bitmap (1:1 pixels). `outline` is the visible outer outline width in px.
    static func image(lines: [Line], align: Align, gap: CGFloat, pad: CGFloat, outline: CGFloat, stroke: NSColor,
                      shadow: Shadow? = nil) -> CGImage? {
        guard !lines.isEmpty else { return nil }
        let (w, h) = bitmapSize(lines: lines, gap: gap, pad: pad, outline: outline)
        guard w > 0, h > 0, w < 16000, h < 16000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        draw(lines: lines, align: align, gap: gap, outline: outline, stroke: stroke, shadow: shadow, in: ctx, width: CGFloat(w), height: CGFloat(h), inset: pad + ceil(max(outline, 0)))
        return ctx.makeImage()
    }

    /// Draws into `ctx` (origin bottom-left, `width` x `height` pixels); the text block is inset by `inset` from the edges.
    static func draw(lines: [Line], align: Align, gap: CGFloat, outline: CGFloat, stroke: NSColor, shadow: Shadow?,
                     in ctx: CGContext, width: CGFloat, height: CGFloat, inset: CGFloat) {
        let cts = lines.map(ctLine)
        var metrics: [(w: CGFloat, asc: CGFloat, h: CGFloat)] = []
        for ct in cts {
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            let w = CTLineGetTypographicBounds(ct, &asc, &desc, &lead)
            metrics.append((ceil(CGFloat(w)), asc, ceil(asc + desc + lead)))
        }
        let maxW = metrics.map(\.w).max() ?? 0
        // Baseline positions, top to bottom.
        var y = height - inset
        var origins: [CGPoint] = []
        for m in metrics {
            y -= m.h
            let x: CGFloat
            switch align {
            case .left: x = inset
            case .center: x = inset + (maxW - m.w) / 2
            case .right: x = inset + maxW - m.w
            }
            // Baseline sits `asc` below the top of the line box (leading is added below the descent).
            origins.append(CGPoint(x: x, y: y + m.h - m.asc))
            y -= gap
        }
        ctx.saveGState()
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        ctx.setAllowsFontSmoothing(false)
        if let shadow {
            ctx.setShadow(offset: .zero, blur: shadow.blur, color: shadow.color.cgColor)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if outline > 0 {
            ctx.setTextDrawingMode(.stroke)
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.setLineWidth(2 * outline)
            ctx.setStrokeColor(stroke.cgColor)
            for (ct, o) in zip(cts, origins) { ctx.textPosition = o; CTLineDraw(ct, ctx) }
        }
        ctx.setTextDrawingMode(.fill)
        for ((ct, o), line) in zip(zip(cts, origins), lines) {
            ctx.setFillColor(line.fill.cgColor)
            ctx.textPosition = o
            CTLineDraw(ct, ctx)
        }
        if shadow != nil { ctx.endTransparencyLayer() }
        ctx.restoreGState()
    }

    private static func ctLine(_ line: Line) -> CTLine {
        // The colour comes from the context, not from the attributes.
        CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: line.font, NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
    }
}
