import AppKit
import CoreLocation

/// Which parts of the place the location card shows (global per file: automatic card and all card keyframes, preview and export).
struct LocationCardFields: Codable, Equatable {
    var country = true
    var city = true
    var street = false
    var houseNumber = false
    var coordinates = true
    var elevation = true

    init() {}

    /// Missing keys fall back to the defaults, so older or hand-edited files keep loading.
    init(from decoder: Decoder) throws {
        let d = LocationCardFields()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        country = try c.decodeIfPresent(Bool.self, forKey: .country) ?? d.country
        city = try c.decodeIfPresent(Bool.self, forKey: .city) ?? d.city
        street = try c.decodeIfPresent(Bool.self, forKey: .street) ?? d.street
        houseNumber = try c.decodeIfPresent(Bool.self, forKey: .houseNumber) ?? d.houseNumber
        coordinates = try c.decodeIfPresent(Bool.self, forKey: .coordinates) ?? d.coordinates
        elevation = try c.decodeIfPresent(Bool.self, forKey: .elevation) ?? d.elevation
    }
}

/// One line of the card; detail lines (coordinates, elevation) are drawn slightly dimmer.
struct CardLine: Equatable {
    var text: String
    var detail = false
}

/// Where a clip was filmed: GPS position plus the reverse-geocoded place names. Cached as a `location` sidecar (see `Sidecar`)
/// so later opens and exports work offline.
struct PlaceInfo: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var country: String?
    /// Legacy combined "venue/neighbourhood, city" text of caches written before the components existed.
    var place: String?
    /// Metres; optional so caches written before altitude existed still decode (refreshed from the telemetry on open).
    var altitude: Double?
    /// City (locality, else sub-locality / administrative area), street and house number.
    var city: String?
    var street: String?
    var houseNumber: String?

    /// A legacy cache (combined `place` text, no components): looked up again once when online.
    var isStale: Bool { place != nil && city == nil }

    static func cached(for url: URL, matching fix: Telemetry.GPSFix) -> PlaceInfo? {
        guard let data = Sidecar.read(for: url, kind: "location"), let p = try? JSONDecoder().decode(PlaceInfo.self, from: data),
              abs(p.latitude - fix.latitude) < 1e-6, abs(p.longitude - fix.longitude) < 1e-6 else { return nil }
        return p
    }

    /// Reverse geocodes (needs network); nil when the lookup fails.
    static func geocode(fix: Telemetry.GPSFix) async -> PlaceInfo? {
        let loc = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "en_US")).first else { return nil }
        var info = PlaceInfo(latitude: fix.latitude, longitude: fix.longitude, altitude: fix.altitude)
        info.country = mark.country
        info.city = mark.locality ?? mark.subLocality ?? mark.administrativeArea
        info.street = mark.thoroughfare
        info.houseNumber = mark.subThoroughfare
        return info
    }

    /// Reverse geocodes; coordinates only when the lookup fails. Failures are not cached.
    static func lookup(fix: Telemetry.GPSFix, cacheFor url: URL) async -> PlaceInfo {
        guard let info = await geocode(fix: fix) else { return PlaceInfo(latitude: fix.latitude, longitude: fix.longitude, altitude: fix.altitude) }
        info.save(for: url)
        return info
    }

    /// Cache, else lookup. A legacy cache is looked up again once; if that fails it keeps being used as it is.
    static func resolve(fix: Telemetry.GPSFix, cacheFor url: URL) async -> PlaceInfo {
        guard let cached = cached(for: url, matching: fix) else { return await lookup(fix: fix, cacheFor: url) }
        if cached.isStale {
            if let fresh = await geocode(fix: fix) { fresh.save(for: url); return fresh }
            return cached.withAltitude(of: fix)
        }
        let info = cached.withAltitude(of: fix)
        if info != cached { info.save(for: url) }   // refresh caches written before altitude existed
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

    /// Card lines in order: country, "Street Number", city, coordinates, elevation. Parts that are switched off or missing
    /// are left out (a house number without a street is never shown). Legacy caches show their combined text as the city.
    func cardLines(_ f: LocationCardFields = LocationCardFields()) -> [CardLine] {
        var out: [CardLine] = []
        if f.country, let country { out.append(CardLine(text: country)) }
        if f.street, let street { out.append(CardLine(text: [street, f.houseNumber ? houseNumber : nil].compactMap { $0 }.joined(separator: " "))) }
        if f.city, let c = city ?? place { out.append(CardLine(text: c)) }
        if f.coordinates { out.append(CardLine(text: coordinateText, detail: true)) }
        if f.elevation, let altitudeText { out.append(CardLine(text: altitudeText, detail: true)) }
        return out
    }

    func lines(_ f: LocationCardFields = LocationCardFields()) -> [String] { cardLines(f).map(\.text) }
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

    static func image(for info: PlaceInfo, placement: OverlayPlacement, style: LocationCardStyle = LocationCardStyle(),
                      fields: LocationCardFields = LocationCardFields()) -> CGImage? {
        let lines = info.cardLines(fields)
        guard !lines.isEmpty else { return nil }
        let sizes = style.sizes(lineCount: lines.count)
        let attributed = zip(lines, sizes).enumerated().map { i, pair -> NSAttributedString in
            let (line, size) = pair
            let text = line.text
            let font = style.font(size: size, bold: i == 0)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = .zero
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .shadow: shadow,
                .foregroundColor: style.fill.nsColor.withAlphaComponent(CGFloat(style.fill.a) * (line.detail ? 0.85 : 1))]
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
