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
    case audio = "Audio"

    var isRegion: Bool { self == .cuts || self == .captions || self == .audio }
}

/// Zoom, tick and autoscroll rules of the timeline strip (pure).
enum TimelineWindow {
    /// Zoomed in this far the ticks can reach milliseconds (`minTickStep`) on a normal strip width.
    static let minVisible = 0.1
    /// The finest tick step in seconds: 1 ms.
    static let minTickStep = 0.001
    static let defaultVisible = 30.0
    /// Distance from the strip edge (px) where drag autoscroll starts.
    static let autoscrollZone = 28.0
    /// Closest allowed spacing in px of the ticks that are drawn fully; the finer decade fades out below it.
    static let minTickSpacing = 6.0
    /// Spacing in px at which the finer decade is gone completely.
    static let fadeTickSpacing = 2.0
    /// The window may be zoomed out to this many times the video length, so that the whole video fits even when the
    /// playhead (the centre of the window) is at its start or end.
    static let overviewFactor = 2.0

    /// Window length limited to `minVisible` ... `overviewFactor` times the video (never below `minVisible`, also for tiny clips).
    static func clampVisible(_ v: Double, duration: Double) -> Double {
        let upper = max(duration * overviewFactor, minVisible)
        guard v.isFinite else { return min(defaultVisible, upper) }
        return max(minVisible, min(v, upper))
    }

    static func initialVisible(duration: Double) -> Double { clampVisible(min(defaultVisible, max(duration, minVisible)), duration: duration) }

    /// Multiplicative zoom factor (to apply to the visible duration) for a wheel event. Positive delta zooms in.
    /// Discrete wheels give about 1 per notch (10 % per notch), trackpads many small point deltas.
    static func wheelFactor(deltaY: Double, precise: Bool) -> Double {
        exp(-deltaY * (precise ? 0.01 : 0.1))
    }

    /// Factor for a pinch (`NSEvent.magnification`, positive = spread = zoom in).
    static func magnifyFactor(_ magnification: Double) -> Double { 1 / max(1 + magnification, 0.1) }

    /// Seconds between ticks, decimal like `PCBGridStep.decimalStep` in PCBDesigner: the smallest power of ten (1 ms, 10 ms,
    /// ... 1 s, 10 s, 100 s, ...) whose spacing is at least `minTickSpacing` px, so every 10th tick of a level lands on a
    /// round value.
    static func tickStep(pixelsPerSecond: Double) -> Double {
        guard pixelsPerSecond > 0 else { return 1e9 }
        let minSeconds = minTickSpacing / pixelsPerSecond
        let exponent = max(ceil(log10(minSeconds) - 1e-9), log10(minTickStep).rounded())
        return pow(10, exponent)
    }

    /// Index of a tick of `step` (time = index * step).
    static func tickIndex(_ time: Double, step: Double) -> Int { Int((time / step).rounded()) }

    /// Every 10th tick of a level is a large one (it is also a tick of the next coarser decade).
    static func isLargeTick(_ time: Double, step: Double) -> Bool { tickIndex(time, step: step) % 10 == 0 }

    /// Label of a large tick: "m:ss" for whole seconds, with as many decimals as the spacing of the large ticks needs
    /// (`step` is the step of the small ticks, large ticks are 10x further apart): "0:12.5", "0:12.05", "0:12.005".
    static func largeTickText(_ time: Double, step: Double) -> String {
        let decimals = max(0, Int((-log10(step * 10)).rounded()))
        return TimelineLayout.timeText(time, decimals: decimals)
    }

    /// Opacity (0...1) of the ticks of the next finer decade (`step / 10`): fully visible just when that decade is
    /// dense enough to be the step itself, fading out as it gets denser, gone below `fadeTickSpacing`. 0 when there is
    /// no finer decade (the step is the finest, 1 ms).
    static func fineTickAlpha(pixelsPerSecond: Double, step: Double) -> Double {
        guard step > minTickStep * 1.5 else { return 0 }
        let spacing = step / 10 * pixelsPerSecond
        return max(0, min(1, (spacing - fadeTickSpacing) / (minTickSpacing - fadeTickSpacing)))
    }

    /// Multiples of `step` (absolute time) inside `range` and `0...duration`.
    static func ticks(in range: ClosedRange<Double>, step: Double, duration: Double) -> [Double] {
        guard step > 0, duration >= 0 else { return [] }
        let lo = max(range.lowerBound, 0), hi = min(range.upperBound, duration)
        guard lo <= hi else { return [] }
        var out: [Double] = []
        var k = (lo / step).rounded(.up)
        while k * step <= hi + 1e-9 && out.count < 10_000 { out.append(k * step); k += 1 }
        return out
    }

    /// Autoscroll speed in seconds of timeline per second while a drag is held near an edge: 0 farther than the zone
    /// from the edge, 0.4 visible-seconds per second at the edge, growing linearly with overshoot (capped at 3x the zone depth).
    /// Negative (towards the start) at the left edge.
    static func autoscrollSpeed(pointerX: Double, width: Double, visible: Double) -> Double {
        guard width > 0 else { return 0 }
        let leftDepth = (autoscrollZone - pointerX) / autoscrollZone
        let rightDepth = (pointerX - (width - autoscrollZone)) / autoscrollZone
        if leftDepth > 0 { return -0.4 * visible * min(leftDepth, 3) }
        if rightDepth > 0 { return 0.4 * visible * min(rightDepth, 3) }
        return 0
    }
}

/// Strip geometry and hit testing, separate from drawing so it can be tested. The strip shows `visible` seconds centred
/// on `center`, so the time at the horizontal middle is `center` (the playhead); x and time are not clamped to the video.
struct TimelineLayout {
    var width: Double
    var duration: Double
    var center: Double
    var visible: Double
    var handleSlop = 6.0     // how close a click must be to a region edge to grab it

    /// `visible` defaults to the whole `duration`, `center` to 0.
    init(width: Double, duration: Double, center: Double = 0, visible: Double? = nil) {
        self.width = width
        self.duration = duration
        self.center = center
        self.visible = max(visible ?? duration, 0.1)
    }

    enum Hit: Equatable {
        case point(UUID)
        case region(UUID)
        case regionStart(UUID)
        case regionEnd(UUID)
    }

    var pixelsPerSecond: Double { max(width, 1) / visible }
    func x(_ time: Double) -> Double { width / 2 + (time - center) * pixelsPerSecond }
    func time(_ x: Double) -> Double { center + (x - width / 2) / pixelsPerSecond }
    /// Times shown by the window.
    var visibleRange: ClosedRange<Double> { time(0)...time(width) }

    /// The ONE place that places the playhead: always the horizontal centre.
    var playheadX: Double { width / 2 }

    /// Left edge of a label of `labelWidth` centred on `centerX`, kept inside 0...width.
    func labelOriginX(centerX: Double, labelWidth: Double) -> Double {
        max(0, min(centerX - labelWidth / 2, max(width - labelWidth, 0)))
    }

    /// "m:ss", or "h:mm:ss" from one hour on.
    static func timeText(_ seconds: Double) -> String {
        let t = Int(max(seconds.isFinite ? seconds : 0, 0))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }

    /// "m:ss.fff" with `decimals` decimals (0 = "m:ss"), "h:mm:ss.fff" from one hour on. Rounded to the shown precision.
    static func timeText(_ seconds: Double, decimals: Int) -> String {
        guard decimals > 0 else { return timeText(seconds) }
        let scale = pow(10.0, Double(decimals))
        let units = Int((max(seconds.isFinite ? seconds : 0, 0) * scale).rounded())
        let whole = units / Int(scale), frac = units % Int(scale)
        let base = whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) : String(format: "%d:%02d", whole / 60, whole % 60)
        return base + "." + String(format: "%0\(decimals)d", frac)
    }

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
        // Ties (overlapping regions with the same edge) go to the later one.
        if let best = edges.reversed().min(by: { distance($0.0, $0.1, px) < distance($1.0, $1.1, px) }) { return best.1 }
        // Overlapping regions (audio clips): the selected one wins, else the latest in the list (drawn on top).
        func contains(_ r: TimelineItem) -> Bool { px >= x(r.start) && px <= x(r.end ?? r.start) }
        if let sel = regions.first(where: { $0.id == selected }), contains(sel) { return .region(sel.id) }
        if let r = regions.last(where: contains) { return .region(r.id) }
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
