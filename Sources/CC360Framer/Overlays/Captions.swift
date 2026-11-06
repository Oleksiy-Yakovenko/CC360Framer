import AppKit

/// Look of captions. Defaults: bottom centre, bold system font, white with a black outline, size relative to the
/// frame's short side so it looks the same at every export size.
struct CaptionStyle: Codable, Equatable {
    /// Name used by a per-caption override to ask for the system font (an override of nil means "inherit").
    static let systemFontName = "System"
    /// Size range as a fraction of the frame's short side.
    static let sizeRange = 0.02...0.15

    /// Font family; nil = the system font.
    var fontName: String?
    /// Font size as a fraction of the frame's short side.
    var size: Double
    var fill: CardColor
    var stroke: CardColor
    /// Outline width as a percentage of the font size (0 = none).
    var strokeWidth: Double
    var placement: OverlayPlacement

    init(fontName: String? = nil, size: Double = 0.055, fill: CardColor = CardColor(r: 1, g: 1, b: 1),
         stroke: CardColor = CardColor(r: 0, g: 0, b: 0), strokeWidth: Double = 7, placement: OverlayPlacement = .bottomCenter) {
        self.fontName = fontName; self.size = size; self.fill = fill; self.stroke = stroke
        self.strokeWidth = strokeWidth; self.placement = placement
    }

    /// Missing or invalid keys fall back to the defaults.
    init(from decoder: Decoder) throws {
        let d = CaptionStyle()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try? c.decodeIfPresent(String.self, forKey: .fontName)
        size = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? d.size
        fill = (try? c.decodeIfPresent(CardColor.self, forKey: .fill)) ?? d.fill
        stroke = (try? c.decodeIfPresent(CardColor.self, forKey: .stroke)) ?? d.stroke
        strokeWidth = (try? c.decodeIfPresent(Double.self, forKey: .strokeWidth)) ?? d.strokeWidth
        placement = (try? c.decodeIfPresent(OverlayPlacement.self, forKey: .placement)) ?? d.placement
    }

    static let defaultsKey = "captionStyle"

    static func loadDefaults(_ d: UserDefaults = .standard) -> CaptionStyle {
        guard let data = d.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(CaptionStyle.self, from: data) else { return CaptionStyle() }
        return s
    }

    func saveDefaults(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }

    func font(pixelSize: CGFloat) -> NSFont {
        if let fontName, let f = NSFontManager.shared.font(withFamily: fontName, traits: .boldFontMask, weight: 9, size: pixelSize) { return f }
        return .systemFont(ofSize: pixelSize, weight: .bold)
    }
}

/// Per-caption changes to the global style; nil fields inherit.
struct CaptionOverrides: Codable, Equatable {
    var fontName: String?
    var size: Double?
    var fill: CardColor?
    var stroke: CardColor?
    var strokeWidth: Double?
    var placement: OverlayPlacement?

    var isEmpty: Bool { self == CaptionOverrides() }

    init(fontName: String? = nil, size: Double? = nil, fill: CardColor? = nil, stroke: CardColor? = nil,
         strokeWidth: Double? = nil, placement: OverlayPlacement? = nil) {
        self.fontName = fontName; self.size = size; self.fill = fill; self.stroke = stroke
        self.strokeWidth = strokeWidth; self.placement = placement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try? c.decodeIfPresent(String.self, forKey: .fontName)
        size = try? c.decodeIfPresent(Double.self, forKey: .size)
        fill = try? c.decodeIfPresent(CardColor.self, forKey: .fill)
        stroke = try? c.decodeIfPresent(CardColor.self, forKey: .stroke)
        strokeWidth = try? c.decodeIfPresent(Double.self, forKey: .strokeWidth)
        placement = try? c.decodeIfPresent(OverlayPlacement.self, forKey: .placement)
    }

    /// The style of a caption: the global one with these overrides applied.
    func resolved(over base: CaptionStyle) -> CaptionStyle {
        var s = base
        if let fontName { s.fontName = fontName == CaptionStyle.systemFontName ? nil : fontName }
        if let size { s.size = min(max(size, CaptionStyle.sizeRange.lowerBound), CaptionStyle.sizeRange.upperBound) }
        if let fill { s.fill = fill }
        if let stroke { s.stroke = stroke }
        if let strokeWidth { s.strokeWidth = max(0, strokeWidth) }
        if let placement { s.placement = placement }
        return s
    }
}

/// A piece of text shown from `start` to `end` (source seconds).
struct Caption: Codable, Equatable, Identifiable, TimeRegion {
    /// Length of the fade in and out.
    static let fade = 0.2

    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var overrides: CaptionOverrides?

    init(id: UUID = UUID(), start: Double, end: Double, text: String = "Caption", overrides: CaptionOverrides? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text; self.overrides = overrides
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        overrides = try? c.decodeIfPresent(CaptionOverrides.self, forKey: .overrides)
    }

    func style(over base: CaptionStyle) -> CaptionStyle { (overrides ?? CaptionOverrides()).resolved(over: base) }

    /// Opacity at `t`: 0 outside, fading in and out over `fade` (at most half the caption's length).
    func alpha(at t: Double) -> Float {
        guard t >= start, t < end else { return 0 }
        let f = max(min(Self.fade, (end - start) / 2), 1e-6)
        return Float(max(0, min(1, min((t - start) / f, (end - t) / f))))
    }
}

enum CaptionLogic {
    /// Captions with their opacity that are visible at source time `t`, in start order. Empty text is never shown.
    static func active(_ captions: [Caption], at t: Double) -> [(caption: Caption, alpha: Float)] {
        captions.sorted { $0.start < $1.start }.compactMap { c in
            guard !c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let a = c.alpha(at: t)
            return a > 0 ? (c, a) : nil
        }
    }
}

enum CaptionOverlay {
    /// Short side used when no target size is given.
    static let referenceShort: CGFloat = 2160

    /// Bitmap of the caption text (multi-line, aligned by the placement) with an outline, rasterised for a frame whose
    /// short side is `short` pixels (font pixel size = `style.size * short`, so it is drawn 1:1 into such a frame).
    static func image(text: String, style: CaptionStyle, short: CGFloat = referenceShort) -> CGImage? {
        let px = CGFloat(style.size) * short
        let para = NSMutableParagraphStyle()
        switch style.placement.anchor.x {
        case -1: para.alignment = .left
        case 1: para.alignment = .right
        default: para.alignment = .center
        }
        var attrs: [NSAttributedString.Key: Any] = [.font: style.font(pixelSize: px), .paragraphStyle: para,
                                                    .foregroundColor: style.fill.nsColor]
        if style.strokeWidth > 0 {
            attrs[.strokeColor] = style.stroke.nsColor
            attrs[.strokeWidth] = -style.strokeWidth   // negative = stroke and fill; percent of the font size
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        let bounds = str.boundingRect(with: NSSize(width: 100_000, height: 100_000), options: [.usesLineFragmentOrigin])
        let pad = ceil(px * 0.25)
        let w = Int(ceil(bounds.width) + 2 * pad), h = Int(ceil(bounds.height) + 2 * pad)
        guard w > 0, h > 0, w < 16000, h < 16000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        str.draw(with: NSRect(x: pad, y: pad, width: ceil(bounds.width), height: ceil(bounds.height)), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

/// Caption bitmaps, rebuilt only when a caption's text or resolved style changes (not on every frame or every model change).
final class CaptionImageCache {
    private struct Signature: Equatable {
        var text: String
        var style: CaptionStyle
        var targetShort: Int
    }
    private var entries: [UUID: (sig: Signature, image: CGImage?)] = [:]
    private(set) var renders = 0

    /// Bitmaps for all captions (keyed by `OverlayPlan.captionImageKey`); entries of deleted captions are dropped.
    func images(for captions: [Caption], style: CaptionStyle, targetShort: Int = 1080) -> [String: CGImage] {
        var out: [String: CGImage] = [:]
        var kept: [UUID: (sig: Signature, image: CGImage?)] = [:]
        for c in captions where !c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let sig = Signature(text: c.text, style: c.style(over: style), targetShort: targetShort)
            if let e = entries[c.id], e.sig == sig {
                kept[c.id] = e
            } else {
                renders += 1
                kept[c.id] = (sig, CaptionOverlay.image(text: sig.text, style: sig.style, short: CGFloat(targetShort)))
            }
            if let img = kept[c.id]?.image { out[OverlayPlan.captionImageKey(c.id)] = img }
        }
        entries = kept
        return out
    }
}
