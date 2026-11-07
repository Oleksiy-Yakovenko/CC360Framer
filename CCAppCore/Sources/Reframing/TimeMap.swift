import Foundation

/// A removed stretch of the source video, in source seconds. Stored in the project sidecar.
struct CutRegion: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
}

/// Maps between source time and output time once cut regions are removed. Pure logic, no AVFoundation.
///
/// Crossfade semantics: at each cut the end of the earlier kept segment and the start of the later one OVERLAP in the
/// output by the (effective) crossfade length, so the two segments dissolve into each other. Only kept material is
/// ever shown (never footage from inside a cut), and every interior cut makes the output that much shorter:
/// `outputDuration = kept - sum(effective crossfades)`. The effective crossfade at a cut is limited to half the
/// length of each neighbouring segment so a segment never fades in and out over the same stretch. A cut at the very
/// start or end of the clip has no neighbour on one side and therefore no dissolve.
struct TimeMap: Equatable {
    struct Segment: Equatable {
        var sourceStart: Double
        var sourceEnd: Double
        /// Output time of `sourceStart`.
        var outputStart: Double
        var length: Double { sourceEnd - sourceStart }
        var outputEnd: Double { outputStart + length }
    }

    /// What to show at one output time: `from` is the source time of the main frame; when `to` is set the frame at
    /// source time `to` dissolves in with weight `mix` (0...1) over the frame at `from`.
    struct Sample: Equatable {
        var from: Double
        var to: Double?
        var mix: Double
        /// Index into `segments` of the one `from` belongs to; `to` belongs to the next one.
        var segment = 0
    }

    /// Shortest cut or kept segment that is still considered real (below this, regions are dropped / merged).
    static let epsilon = 1e-3

    let duration: Double
    let segments: [Segment]
    /// `fades[i]`: effective dissolve length between segment i and i + 1.
    let fades: [Double]

    /// Cuts are clamped to the clip, sorted, and overlapping or touching ones merged first.
    init(cuts: [CutRegion], duration: Double, crossfade: Double = 0) {
        self.duration = max(duration, 0)
        let merged = Self.normalized(cuts, duration: self.duration)
        var kept: [(Double, Double)] = []
        var cursor = 0.0
        for c in merged {
            if c.start - cursor > Self.epsilon { kept.append((cursor, c.start)) }
            cursor = c.end
        }
        if self.duration - cursor > Self.epsilon { kept.append((cursor, self.duration)) }

        var segs: [Segment] = []
        var fades: [Double] = []
        var out = 0.0
        for (i, k) in kept.enumerated() {
            var f = 0.0
            if i > 0 {
                let prev = kept[i - 1]
                f = max(0, min(crossfade, (prev.1 - prev.0) / 2, (k.1 - k.0) / 2))
                if f < Self.epsilon { f = 0 }
                fades.append(f)
            }
            let start = out - f
            segs.append(Segment(sourceStart: k.0, sourceEnd: k.1, outputStart: start))
            out = start + (k.1 - k.0)
        }
        segments = segs
        self.fades = fades
    }

    /// Sorted, clamped, merged copy of `cuts` without empty regions.
    static func normalized(_ cuts: [CutRegion], duration: Double) -> [(start: Double, end: Double)] {
        let clamped = cuts.map { (start: max(0, min($0.start, duration)), end: max(0, min($0.end, duration))) }
            .filter { $0.end - $0.start > epsilon }
            .sorted { $0.start < $1.start }
        var out: [(start: Double, end: Double)] = []
        for c in clamped {
            if let last = out.last, c.start <= last.end + epsilon { out[out.count - 1].end = max(last.end, c.end) } else { out.append(c) }
        }
        return out
    }

    var hasCuts: Bool { segments.count != 1 || segments.first.map { $0.length < duration - Self.epsilon } ?? true }
    var outputDuration: Double { segments.last?.outputEnd ?? 0 }
    var totalCrossfade: Double { fades.reduce(0, +) }

    /// Output time to what should be drawn. Times outside the output clamp to its ends; nil when everything is cut.
    func sample(atOutput t: Double) -> Sample? {
        guard !segments.isEmpty else { return nil }
        let t = max(0, min(t, outputDuration))
        var i = 0
        while i + 1 < segments.count, segments[i + 1].outputStart <= t { i += 1 }
        let seg = segments[i]
        let from = min(seg.sourceStart + (t - seg.outputStart), seg.sourceEnd)
        if i > 0, fades[i - 1] > 0 {
            let into = t - seg.outputStart
            if into < fades[i - 1] {
                // Inside the overlap: the previous segment is still running underneath.
                let prev = segments[i - 1]
                let outgoing = min(prev.sourceStart + (t - prev.outputStart), prev.sourceEnd)
                return Sample(from: outgoing, to: from, mix: max(0, min(1, into / fades[i - 1])), segment: i - 1)
            }
        }
        return Sample(from: from, to: nil, mix: 0, segment: i)
    }

    /// Source time shown (mostly) at output time `t`: the incoming segment once a dissolve is past half-way.
    func sourceTime(atOutput t: Double) -> Double? {
        guard let s = sample(atOutput: t) else { return nil }
        return (s.to != nil && s.mix >= 0.5) ? s.to : s.from
    }

    /// Output time of a source time; nil when it lies inside a cut. In a dissolve overlap this is the incoming segment's time.
    func outputTime(atSource s: Double) -> Double? {
        for seg in segments.reversed() where s >= seg.sourceStart - Self.epsilon && s <= seg.sourceEnd + Self.epsilon {
            return seg.outputStart + max(0, min(s, seg.sourceEnd) - seg.sourceStart)
        }
        return nil
    }

    /// Where playback should jump when the playhead is at source time `s`: `s` itself when kept, otherwise the end of
    /// the cut it is in (clamped to the duration). Used to skip cuts in the preview.
    func skipTarget(forSource s: Double) -> Double {
        if segments.contains(where: { s >= $0.sourceStart - Self.epsilon && s < $0.sourceEnd }) { return s }
        return segments.first(where: { $0.sourceStart > s })?.sourceStart ?? duration
    }

    /// One dissolve seen from the preview, in SOURCE time. The outgoing segment keeps playing from `outStart` to
    /// `outEnd` (its end) while the incoming one plays from `inStart` for `length`; the preview player of the
    /// incoming segment then takes over at `landing`.
    struct Overlap: Equatable {
        /// Index of the outgoing segment; the incoming one is `segment + 1`.
        var segment: Int
        var outStart: Double
        var outEnd: Double
        var inStart: Double
        var length: Double

        /// Where the main player continues after the dissolve (the incoming time at `outEnd`).
        var landing: Double { inStart + length }
        /// Dissolve weight of the incoming frame (0...1, linear like the export) for an outgoing source time.
        func mix(atOutgoing t: Double) -> Double { max(0, min(1, (t - outStart) / length)) }
        /// Source time of the incoming frame shown together with the outgoing frame at `t`.
        func incomingTime(forOutgoing t: Double) -> Double { inStart + max(0, min(length, t - outStart)) }
        /// Source time of the outgoing frame shown together with the incoming frame at `t`.
        func outgoingTime(forIncoming t: Double) -> Double { outStart + max(0, min(length, t - inStart)) }
        /// True while the outgoing playhead `t` is inside the dissolve (its end excluded: there the incoming player takes over).
        func contains(outgoing t: Double) -> Bool { t >= outStart && t < outEnd }
    }

    /// The dissolves of this map in source order (cuts with an effective crossfade of 0 have none).
    var overlaps: [Overlap] {
        fades.enumerated().compactMap { i, f in
            guard f > 0 else { return nil }
            return Overlap(segment: i, outStart: segments[i].sourceEnd - f, outEnd: segments[i].sourceEnd, inStart: segments[i + 1].sourceStart, length: f)
        }
    }

    /// The dissolve whose outgoing part contains source time `t`, if any.
    func overlap(atOutgoingSource t: Double) -> Overlap? { overlaps.first { $0.contains(outgoing: t) } }

    /// The first dissolve that starts after source time `t`.
    func nextOverlap(after t: Double) -> Overlap? { overlaps.first { $0.outStart > t } }

    /// Jumps the preview must make by seeking: cuts without a dissolve (hard cut, crossfade 0 or segments too short),
    /// and the cut at the very end. Cuts with a dissolve are handled by the second player (`overlaps`).
    var hardJumps: [(from: Double, to: Double)] {
        jumpPoints.enumerated().filter { i, _ in !(i < fades.count && fades[i] > 0) }.map(\.element)
    }

    /// Source start times of cuts that follow a kept segment (where the preview must jump).
    var jumpPoints: [(from: Double, to: Double)] {
        var pts: [(Double, Double)] = []
        for (i, seg) in segments.enumerated() {
            if i + 1 < segments.count { pts.append((seg.sourceEnd, segments[i + 1].sourceStart)) } else if seg.sourceEnd < duration - Self.epsilon { pts.append((seg.sourceEnd, duration)) }
        }
        return pts
    }
}
