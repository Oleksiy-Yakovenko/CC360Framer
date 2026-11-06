import AppKit
import CoreLocation

/// Where a clip was filmed: GPS position plus the reverse-geocoded place names. Cached in `<file>.location.json`
/// so later opens and exports work offline.
struct PlaceInfo: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var country: String?
    var place: String?

    static func sidecar(for url: URL) -> URL { url.appendingPathExtension("location.json") }

    static func cached(for url: URL, matching fix: Telemetry.GPSFix) -> PlaceInfo? {
        guard let data = try? Data(contentsOf: sidecar(for: url)), let p = try? JSONDecoder().decode(PlaceInfo.self, from: data),
              abs(p.latitude - fix.latitude) < 1e-6, abs(p.longitude - fix.longitude) < 1e-6 else { return nil }
        return p
    }

    /// Reverse geocodes (needs network). Falls back to coordinates only when the lookup fails; failures are not cached.
    static func lookup(fix: Telemetry.GPSFix, cacheFor url: URL) async -> PlaceInfo {
        var info = PlaceInfo(latitude: fix.latitude, longitude: fix.longitude)
        let loc = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
        guard let mark = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "en_US")).first else { return info }
        info.country = mark.country
        let parts = [mark.name.flatMap { $0 == mark.thoroughfare ? nil : $0 }, mark.subLocality, mark.locality].compactMap { $0 }
        info.place = parts.first.map { first in
            // "Street, City" reads better than a lone venue or neighbourhood name.
            [first, mark.locality].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: ", ")
        } ?? mark.administrativeArea
        if let data = try? JSONEncoder().encode(info) { try? data.write(to: sidecar(for: url)) }
        return info
    }

    var coordinateText: String {
        String(format: "%.5f° %@, %.5f° %@", abs(latitude), latitude >= 0 ? "N" : "S", abs(longitude), longitude >= 0 ? "E" : "W")
    }

    /// Country, place, coordinates (missing names are left out).
    var lines: [String] { [country, place, coordinateText].compactMap { $0 } }
}

/// Where the card sits in the frame; also sets the text alignment inside the card.
enum OverlayPlacement: String, CaseIterable, Identifiable {
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

/// Title card shown at the start of the clip, drawn once into a bitmap and composited by the renderer.
enum LocationOverlay {
    static let visibleSeconds = 10.0
    private static let fade = 0.6

    /// Opacity at video time `t`: fades in, holds, fades out, gone after `visibleSeconds`.
    static func alpha(at t: Double) -> Float {
        guard t >= 0, t < visibleSeconds else { return 0 }
        return Float(max(0, min(1, min(t / fade, (visibleSeconds - t) / fade))))
    }

    static func image(for info: PlaceInfo, placement: OverlayPlacement) -> CGImage? {
        let lines = info.lines
        let sizes: [CGFloat] = lines.count == 3 ? [64, 44, 34] : Array(repeating: 44, count: lines.count)
        let attributed = zip(lines, sizes).enumerated().map { i, pair -> NSAttributedString in
            let (text, size) = pair
            let font = NSFont.systemFont(ofSize: size, weight: i == 0 ? .bold : .regular)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = .zero
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(i == lines.count - 1 ? 0.85 : 1), .shadow: shadow])
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
