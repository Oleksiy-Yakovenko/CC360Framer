import AppKit
import CoreLocation

/// Where a clip was filmed: GPS position plus the reverse-geocoded place names. Cached as a `location` sidecar (see `Sidecar`)
/// so later opens and exports work offline.
struct PlaceInfo: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var country: String?
    var place: String?
    /// Metres; optional so caches written before altitude existed still decode (refreshed from the telemetry on open).
    var altitude: Double?

    static func cached(for url: URL, matching fix: Telemetry.GPSFix) -> PlaceInfo? {
        guard let data = Sidecar.read(for: url, kind: "location"), let p = try? JSONDecoder().decode(PlaceInfo.self, from: data),
              abs(p.latitude - fix.latitude) < 1e-6, abs(p.longitude - fix.longitude) < 1e-6 else { return nil }
        return p
    }

    /// Reverse geocodes (needs network). Falls back to coordinates only when the lookup fails; failures are not cached.
    static func lookup(fix: Telemetry.GPSFix, cacheFor url: URL) async -> PlaceInfo {
        var info = PlaceInfo(latitude: fix.latitude, longitude: fix.longitude, altitude: fix.altitude)
        let loc = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "en_US")).first else { return info }
        info.country = mark.country
        let parts = [mark.name.flatMap { $0 == mark.thoroughfare ? nil : $0 }, mark.subLocality, mark.locality].compactMap { $0 }
        info.place = parts.first.map { first in
            // "Street, City" reads better than a lone venue or neighbourhood name.
            [first, mark.locality].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
        } ?? mark.administrativeArea
        info.save(for: url)
        return info
    }

    func save(for url: URL) {
        if let data = try? JSONEncoder().encode(self) { Sidecar.write(data, for: url, kind: "location") }
    }

    /// A cached entry with the altitude of this fix (older caches have none).
    func withAltitude(of fix: Telemetry.GPSFix) -> PlaceInfo {
        var p = self
        p.altitude = fix.altitude
        return p
    }

    var altitudeText: String? { altitude.map { String(format: "%.0f m", $0) } }

    var coordinateText: String {
        String(format: "%.5f° %@, %.5f° %@", abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
    }

    /// Country, place, coordinates, altitude (missing parts are left out).
    var lines: [String] { [country, place, coordinateText, altitudeText].compactMap { $0 } }
}

/// Where the card sits in the frame; also sets the text alignment inside the card.
enum OverlayPlacement: String, CaseIterable, Identifiable, Codable {
    case topLeft = "Top left", topCenter = "Top centre", topRight = "Top right"
    case center = "Centre"
    case bottomLeft = "Bottom left", bottomCenter = "Bottom centre", bottomRight = "Bottom right"
    var id: String { rawValue }
    /// Horizontal / vertical anchor: -1 = left / bottom, 0 = middle, 1 = right / top.
    var anchor: (x: Float, y: Float) {
        switch self {
        case .topLeft: return (-1, 1)
        case .topCenter: return (0, 1)
        case .topRight: return (1, 1)
        case .center: return (0, 0)
        case .bottomLeft: return (-1, -1)
        case .bottomCenter: return (0, -1)
        case .bottomRight: return (1, -1)
        }
    }
}

/// sRGB colour that can be stored in JSON.
struct CardColor: Codable, Equatable {
    var r, g, b, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? c
        self.init(r: Double(s.redComponent), g: Double(s.greenComponent), b: Double(s.blueComponent), a: Double(s.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

/// Look of the location card. The defaults reproduce the original card: system font, 64 pt headline, white text,
/// a soft black shadow and no outline.
struct LocationCardStyle: Codable, Equatable {
    static let defaultBaseSize = 64.0

    /// Font family; nil = the system font.
    var fontName: String?
    /// Size of the first line in points; the other lines scale with it (44/64 and 34/64 of it).
    var baseSize: Double
    var fill: CardColor
    var stroke: CardColor
    /// Outline width in points (0 = none).
    var strokeWidth: Double

    init(fontName: String? = nil, baseSize: Double = LocationCardStyle.defaultBaseSize,
         fill: CardColor = CardColor(r: 1, g: 1, b: 1), stroke: CardColor = CardColor(r: 0, g: 0, b: 0), strokeWidth: Double = 0) {
        self.fontName = fontName; self.baseSize = baseSize; self.fill = fill; self.stroke = stroke; self.strokeWidth = strokeWidth
    }

    /// Missing keys fall back to the defaults, so older or hand-edited files keep loading.
    init(from decoder: Decoder) throws {
        let d = LocationCardStyle()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName)
        baseSize = try c.decodeIfPresent(Double.self, forKey: .baseSize) ?? d.baseSize
        fill = try c.decodeIfPresent(CardColor.self, forKey: .fill) ?? d.fill
        stroke = try c.decodeIfPresent(CardColor.self, forKey: .stroke) ?? d.stroke
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? d.strokeWidth
    }

    /// Point sizes of the lines: headline, second line, then the details.
    func sizes(lineCount: Int) -> [CGFloat] {
        let k = CGFloat(baseSize / Self.defaultBaseSize)
        return lineCount >= 3 ? [64 * k, 44 * k] + Array(repeating: 34 * k, count: lineCount - 2)
                              : Array(repeating: 44 * k, count: lineCount)
    }

    func font(size: CGFloat, bold: Bool) -> NSFont {
        if let fontName, let f = NSFontManager.shared.font(withFamily: fontName, traits: bold ? .boldFontMask : [], weight: bold ? 9 : 5, size: size) { return f }
        return .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}

/// Title card shown at the start of the clip, drawn once into a bitmap and composited by the renderer.
enum LocationOverlay {
    static let visibleSeconds = 10.0
    private static let fade = 0.6

    /// Opacity at video time `t`: fades in, holds, fades out, gone after `visibleSeconds`.
    static func alpha(at t: Double) -> Float {
        guard t >= 0, t < visibleSeconds else { return 0 }
        return Float(max(0, min(1, min(t / fade, (visibleSeconds - t) / fade))))
    }

    static func image(for info: PlaceInfo, placement: OverlayPlacement, style: LocationCardStyle = LocationCardStyle()) -> CGImage? {
        let lines = info.lines
        let sizes = style.sizes(lineCount: lines.count)
        let detailStart = lines.count - (info.altitude != nil ? 2 : 1)
        let attributed = zip(lines, sizes).enumerated().map { i, pair -> NSAttributedString in
            let (text, size) = pair
            let font = style.font(size: size, bold: i == 0)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = .zero
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .shadow: shadow,
                .foregroundColor: style.fill.nsColor.withAlphaComponent(CGFloat(style.fill.a) * (i >= detailStart ? 0.85 : 1))]
            if style.strokeWidth > 0 {
                attrs[.strokeColor] = style.stroke.nsColor
                attrs[.strokeWidth] = -style.strokeWidth / size * 100   // negative = stroke and fill
            }
            return NSAttributedString(string: text, attributes: attrs)
        }
        let pad: CGFloat = 24, gap: CGFloat = 8
        let widths = attributed.map { ceil($0.size().width) }
        let heights = attributed.map { ceil($0.size().height) }
        let w = Int((widths.max() ?? 1) + 2 * pad), h = Int(heights.reduce(0, +) + gap * CGFloat(max(attributed.count - 1, 0)) + 2 * pad)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        var y = CGFloat(h) - pad
        for (i, a) in attributed.enumerated() {
            y -= heights[i]
            let x: CGFloat
            switch placement.anchor.x {
            case -1: x = pad
            case 0: x = (CGFloat(w) - widths[i]) / 2
            default: x = CGFloat(w) - pad - widths[i]
            }
            a.draw(at: NSPoint(x: x, y: y))
            y -= gap
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
