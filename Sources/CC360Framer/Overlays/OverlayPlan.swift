import CoreGraphics
import Foundation

/// A location card shown from `time` (source seconds) on, with its own placement. The look is the global `LocationCardStyle`.
struct LocationCardKey: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var placement: OverlayPlacement

    init(id: UUID = UUID(), time: Double, placement: OverlayPlacement) { self.id = id; self.time = time; self.placement = placement }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try c.decode(Double.self, forKey: .time)
        placement = (try? c.decodeIfPresent(OverlayPlacement.self, forKey: .placement)) ?? .bottomLeft
    }
}

/// Which location card is on screen at a given source time, and editing rules for the card keyframes.
///
/// Rules: without card keyframes the automatic card (placement from the Location tab) is shown from t = 0 when it is
/// enabled. As soon as at least one card keyframe exists only the keyframes are used (the automatic card is ignored);
/// add a keyframe at 0 to keep a card at the start. A card keyframe shows the card for `LocationOverlay.visibleSeconds`
/// with the usual fades; the next card keyframe replaces it.
enum LocationCards {
    struct Active: Equatable {
        var placement: OverlayPlacement
        var alpha: Float
    }

    /// Keys closer than this are one keyframe.
    static let minSpacing = 0.15

    static func active(keys: [LocationCardKey], autoEnabled: Bool, autoPlacement: OverlayPlacement, at t: Double) -> Active? {
        let a: Active?
        if keys.isEmpty {
            a = autoEnabled ? Active(placement: autoPlacement, alpha: LocationOverlay.alpha(at: t)) : nil
        } else if let k = keys.filter({ $0.time <= t }).max(by: { $0.time < $1.time }) {
            a = Active(placement: k.placement, alpha: LocationOverlay.alpha(at: t - k.time))
        } else {
            a = nil
        }
        return a.flatMap { $0.alpha > 0 ? $0 : nil }
    }

    /// Adds a card at `time` (clamped to the clip). nil when another keyframe is within `minSpacing`.
    static func add(_ keys: [LocationCardKey], at time: Double, placement: OverlayPlacement, duration: Double) -> (keys: [LocationCardKey], added: LocationCardKey)? {
        guard time.isFinite, duration > 0 else { return nil }
        let t = max(0, min(time, duration))
        if keys.contains(where: { abs($0.time - t) < minSpacing }) { return nil }
        let k = LocationCardKey(time: t, placement: placement)
        return ((keys + [k]).sorted { $0.time < $1.time }, k)
    }

    /// Sets time and placement of one card (time clamped to the clip). nil when unknown, not finite or too close to another card.
    static func set(_ keys: [LocationCardKey], id: UUID, time: Double, placement: OverlayPlacement, duration: Double) -> [LocationCardKey]? {
        guard let i = keys.firstIndex(where: { $0.id == id }), time.isFinite else { return nil }
        let t = max(0, duration > 0 ? min(time, duration) : time)
        if keys.enumerated().contains(where: { $0.offset != i && abs($0.element.time - t) < minSpacing }) { return nil }
        var out = keys
        out[i].time = t
        out[i].placement = placement
        return out.sorted { $0.time < $1.time }
    }
}

/// How big an overlay bitmap is drawn.
enum OverlaySize: Equatable {
    /// Bitmap height as a fraction of the frame's short side (the location card).
    case fractionOfShort(Float)
    /// The bitmap was rendered for a frame whose short side is this many pixels, and scales with the real frame (captions).
    case referenceShort(Float)
}

/// One bitmap to composite in the current frame.
struct OverlayDraw: Equatable {
    var key: String
    var placement: OverlayPlacement
    var alpha: Float
    var size: OverlaySize
}

enum OverlayLayout {
    /// Margin to the frame edge as a share of the short side.
    static let margin: Float = 0.04
    /// Widest an overlay may get, as a share of the frame width.
    static let maxWidth: Float = 0.9

    /// Normalised device rectangle (x0, y0, x1, y1) of an overlay bitmap in a target of the given size.
    static func rect(texWidth: Int, texHeight: Int, targetWidth: Float, targetHeight: Float,
                     placement: OverlayPlacement, size: OverlaySize) -> (x0: Float, y0: Float, x1: Float, y1: Float) {
        let short = min(targetWidth, targetHeight)
        var h: Float
        switch size {
        case .fractionOfShort(let f): h = short * f
        case .referenceShort(let ref): h = Float(texHeight) * short / max(ref, 1)
        }
        var w = h * Float(texWidth) / Float(max(texHeight, 1))
        if w > targetWidth * maxWidth { w = targetWidth * maxWidth; h = w * Float(texHeight) / Float(max(texWidth, 1)) }
        let ndcW = 2 * w / targetWidth, ndcH = 2 * h / targetHeight
        let mx = 2 * short * margin / targetWidth, my = 2 * short * margin / targetHeight
        let a = placement.anchor
        let x0 = a.x < 0 ? -1 + mx : a.x > 0 ? 1 - mx - ndcW : -ndcW / 2
        let y0 = a.y < 0 ? -1 + my : a.y > 0 ? 1 - my - ndcH : -ndcH / 2
        return (x0, y0, x0 + ndcW, y0 + ndcH)
    }
}

/// Everything that decides which overlays are drawn at a source time (immutable, so the preview and the export
/// thread can share it).
struct OverlayPlan: Equatable {
    static let empty = OverlayPlan()

    /// False when the file has no GPS place: no location card at all.
    var hasPlace = false
    /// Master switch: false = no location card at all (automatic card and card keyframes).
    var showCard = true
    /// Which parts of the place the card shows.
    var cardFields = LocationCardFields()
    var autoCard = true
    var autoPlacement: OverlayPlacement = .bottomLeft
    var cardKeys: [LocationCardKey] = []
    var captions: [Caption] = []
    /// The global caption style (each caption applies its overrides on top).
    var captionStyle = CaptionStyle()

    static func captionImageKey(_ id: UUID) -> String { "cap.\(id.uuidString)" }

    /// Bitmap key of the location card for a placement: only the text alignment (left / centre / right) changes the bitmap.
    static func cardImageKey(_ p: OverlayPlacement) -> String { "card.\(Int(p.anchor.x))" }

    /// Placements the card can appear with (to know which bitmaps to build).
    var cardPlacements: [OverlayPlacement] {
        guard hasPlace, showCard else { return [] }
        return cardKeys.isEmpty ? (autoCard ? [autoPlacement] : []) : cardKeys.map(\.placement)
    }

    func draws(at t: Double) -> [OverlayDraw] {
        var out: [OverlayDraw] = []
        if hasPlace, showCard, let c = LocationCards.active(keys: cardKeys, autoEnabled: autoCard, autoPlacement: autoPlacement, at: t) {
            out.append(OverlayDraw(key: Self.cardImageKey(c.placement), placement: c.placement, alpha: c.alpha, size: .fractionOfShort(0.4)))
        }
        for (c, alpha) in CaptionLogic.active(captions, at: t) {
            out.append(OverlayDraw(key: Self.captionImageKey(c.id), placement: c.style(over: captionStyle).placement, alpha: alpha,
                                   size: .referenceShort(Float(CaptionOverlay.referenceShort))))
        }
        return out
    }
}

/// Bitmaps plus the plan that says when and where to draw them; handed to the `Renderer` (preview and export).
struct OverlayBundle {
    static let empty = OverlayBundle(images: [:], plan: .empty)
    var images: [String: CGImage]
    var plan: OverlayPlan

    /// Builds the location card bitmaps the plan can use.
    static func make(place: PlaceInfo?, plan: OverlayPlan, style: LocationCardStyle, captionCache: CaptionImageCache = CaptionImageCache()) -> OverlayBundle {
        var images: [String: CGImage] = [:]
        if let place {
            for p in plan.cardPlacements where images[OverlayPlan.cardImageKey(p)] == nil {
                if let img = LocationOverlay.image(for: place, placement: p, style: style, fields: plan.cardFields) { images[OverlayPlan.cardImageKey(p)] = img }
            }
        }
        images.merge(captionCache.images(for: plan.captions, style: plan.captionStyle)) { a, _ in a }
        return OverlayBundle(images: images, plan: plan)
    }
}
