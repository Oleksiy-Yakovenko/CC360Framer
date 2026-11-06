import Foundation

/// A stretch of the source timeline that can be selected and resized (cuts, captions).
protocol TimeRegion: Identifiable where ID == UUID {
    var start: Double { get set }
    var end: Double { get set }
}

extension CutRegion: TimeRegion {}

/// Pure editing rules for region timelines. Regions that must not overlap (cuts) are kept sorted and disjoint;
/// pass `allowOverlap: true` for timelines where they may stack (captions).
enum RegionEdit {
    /// Shortest region the UI creates or accepts.
    static let minLength = 0.2
    /// Length of a region created with "Add".
    static let defaultLength = 3.0

    enum Edge { case start, end }

    /// A new region at the playhead of `length` seconds. It is clamped to the clip (near the end it moves back so it
    /// keeps its length) and, unless overlaps are allowed, shortened to stop at the next region. nil when the playhead
    /// is inside an existing region or no `minLength` of room is left.
    static func add<R: TimeRegion>(_ regions: [R], at playhead: Double, length: Double = defaultLength, duration: Double,
                                   allowOverlap: Bool = false, make: (Double, Double) -> R) -> (regions: [R], added: R)? {
        guard duration >= minLength, playhead.isFinite else { return nil }
        var start = max(0, min(playhead, duration))
        if start + length > duration { start = max(0, duration - length) }
        var end = min(start + length, duration)
        if !allowOverlap {
            if regions.contains(where: { $0.start <= start && start < $0.end }) { return nil }
            if let next = regions.filter({ $0.start >= start }).map(\.start).min() { end = min(end, next) }
        }
        guard end - start >= minLength - 1e-9 else { return nil }
        let r = make(start, end)
        return (sorted(regions + [r]), r)
    }

    /// Moves one edge to `time` for dragging: the edge stops at the clip, at the neighbouring region and at `minLength`
    /// from the other edge, so it never fails.
    static func moveEdge<R: TimeRegion>(_ regions: [R], id: UUID, edge: Edge, to time: Double, duration: Double,
                                        allowOverlap: Bool = false) -> [R] {
        guard let i = regions.firstIndex(where: { $0.id == id }), time.isFinite else { return regions }
        var out = regions
        let r = regions[i]
        let (lo, hi) = bounds(regions, of: r, duration: duration, allowOverlap: allowOverlap)
        switch edge {
        case .start: out[i].start = max(lo, min(time, r.end - minLength))
        case .end: out[i].end = min(hi, max(time, r.start + minLength))
        }
        return out
    }

    /// Sets both times (numeric fields). nil when invalid: not finite, outside the clip, shorter than `minLength`, or
    /// overlapping another region (unless allowed).
    static func setRange<R: TimeRegion>(_ regions: [R], id: UUID, start: Double, end: Double, duration: Double,
                                        allowOverlap: Bool = false) -> [R]? {
        guard let i = regions.firstIndex(where: { $0.id == id }), start.isFinite, end.isFinite,
              start >= 0, end <= duration + 1e-9, end - start >= minLength - 1e-9 else { return nil }
        if !allowOverlap, regions.enumerated().contains(where: { $0.offset != i && $0.element.start < end && start < $0.element.end }) { return nil }
        var out = regions
        out[i].start = start
        out[i].end = min(end, duration)
        return sorted(out)
    }

    static func sorted<R: TimeRegion>(_ regions: [R]) -> [R] { regions.sorted { $0.start < $1.start } }

    /// Room an edge of `r` may move in: between its neighbours (or the clip ends).
    private static func bounds<R: TimeRegion>(_ regions: [R], of r: R, duration: Double, allowOverlap: Bool) -> (Double, Double) {
        guard !allowOverlap else { return (0, duration) }
        let before = regions.filter { $0.id != r.id && $0.end <= r.start + 1e-9 }.map(\.end).max() ?? 0
        let after = regions.filter { $0.id != r.id && $0.start >= r.end - 1e-9 }.map(\.start).min() ?? duration
        return (before, after)
    }
}

/// What a timeline shows: a point (`end == nil`, keyframes) or a region.
struct TimelineItem: Equatable, Identifiable {
    var id: UUID
    var start: Double
    var end: Double?
    var isRegion: Bool { end != nil }
}

/// Which timeline the bottom bar edits. Add cases (location cards, captions) here and give them a `TimelineAdapter`.
enum TimelineKind: String, CaseIterable {
    case keyframes = "Keyframes"
    case cuts = "Cuts"
    case locationCards = "Location cards"
    case captions = "Captions"

    var isRegion: Bool { self == .cuts || self == .captions }
}

/// Seekbar geometry and hit testing, separate from drawing so it can be tested.
struct TimelineLayout {
    var width: Double
    var duration: Double
    var inset = 8.0          // slider thumb radius, so markers line up with the thumb
    var handleSlop = 6.0     // how close a click must be to a region edge to grab it

    enum Hit: Equatable {
        case point(UUID)
        case region(UUID)
        case regionStart(UUID)
        case regionEnd(UUID)
    }

    func x(_ time: Double) -> Double { inset + max(width - inset * 2, 1) * time / max(duration, 0.1) }
    func time(_ x: Double) -> Double { max(0, min(duration, (x - inset) / max(width - inset * 2, 1) * max(duration, 0.1))) }

    /// What a click at `x` grabs. The selected region's edges win, then any region edge, then region bodies, then points.
    func hit(_ items: [TimelineItem], selected: UUID?, at px: Double) -> Hit? {
        let regions = items.filter(\.isRegion)
        func edge(_ r: TimelineItem) -> Hit? {
            guard let end = r.end else { return nil }
            let ds = abs(x(r.start) - px), de = abs(x(end) - px)
            guard min(ds, de) <= handleSlop else { return nil }
            return ds <= de ? .regionStart(r.id) : .regionEnd(r.id)
        }
        if let sel = regions.first(where: { $0.id == selected }), let h = edge(sel) { return h }
        let edges = regions.compactMap { r in edge(r).map { (r, $0) } }
        if let best = edges.min(by: { distance($0.0, $0.1, px) < distance($1.0, $1.1, px) }) { return best.1 }
        if let r = regions.first(where: { px >= x($0.start) && px <= x($0.end ?? $0.start) }) { return .region(r.id) }
        let points = items.filter { !$0.isRegion }
        if let p = points.min(by: { abs(x($0.start) - px) < abs(x($1.start) - px) }), abs(x(p.start) - px) <= 8 { return .point(p.id) }
        return nil
    }

    private func distance(_ r: TimelineItem, _ h: Hit, _ px: Double) -> Double {
        if case .regionEnd = h { return abs(x(r.end ?? r.start) - px) }
        return abs(x(r.start) - px)
    }
}

/// Navigation over a timeline's items.
enum TimelineNav {
    /// The nearest item start before or after `t` (items closer than `tolerance` count as "here").
    static func neighbor(_ items: [TimelineItem], of t: Double, forward: Bool, tolerance: Double = 0.15) -> TimelineItem? {
        let sorted = items.sorted { $0.start < $1.start }
        return forward ? sorted.first { $0.start > t + tolerance } : sorted.last { $0.start < t - tolerance }
    }
}
