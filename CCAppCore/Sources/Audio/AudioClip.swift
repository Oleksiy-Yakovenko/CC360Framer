import Foundation

/// A user-added audio clip (music, voice-over) placed on the source timeline. Clips may overlap; they get mixed.
struct AudioClip: Codable, Equatable, Identifiable, TimeRegion {
    var id = UUID()
    /// Absolute path of the audio file; empty = not chosen yet.
    var path: String
    /// Position on the timeline in seconds of the SOURCE video (like captions and cuts).
    var start: Double
    var end: Double
    /// Where playback starts inside the file, seconds (>= 0).
    var fileOffset: Double
    /// Fade lengths in seconds (>= 0); `fadeIn + fadeOut <= end - start`.
    var fadeIn: Double
    var fadeOut: Double
    /// 0...1.
    var volume: Double

    var length: Double { end - start }

    init(id: UUID = UUID(), path: String = "", start: Double, end: Double, fileOffset: Double = 0,
         fadeIn: Double = 0, fadeOut: Double = 0, volume: Double = 1) {
        self.id = id; self.path = path; self.start = start; self.end = end; self.fileOffset = fileOffset
        self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.volume = volume
        AudioClipEdit.normalize(&self)
    }

    /// Missing or invalid optional keys fall back to defaults; the result is normalised.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        path = (try? c.decodeIfPresent(String.self, forKey: .path)) ?? ""
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        fileOffset = (try? c.decodeIfPresent(Double.self, forKey: .fileOffset)) ?? 0
        fadeIn = (try? c.decodeIfPresent(Double.self, forKey: .fadeIn)) ?? 0
        fadeOut = (try? c.decodeIfPresent(Double.self, forKey: .fadeOut)) ?? 0
        volume = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? 1
        AudioClipEdit.normalize(&self)
    }

    /// Gain at timeline time `t`: 0 outside, linear fades, times `volume`.
    func gain(at t: Double) -> Double {
        guard t >= start, t < end else { return 0 }
        var g = volume
        if fadeIn > 0 { g *= min(1, (t - start) / fadeIn) }
        if fadeOut > 0 { g *= min(1, (end - t) / fadeOut) }
        return g
    }
}

/// Pure editing rules for audio clips. Unlike `RegionEdit` (captions, cuts) clips may overlap, so none of these
/// look at the other clips. Every function keeps the fade/volume/offset invariants.
enum AudioClipEdit {
    static let minLength = RegionEdit.minLength
    static let defaultLength = RegionEdit.defaultLength

    /// Clamps volume, offset and fades into their valid ranges (fades are scaled down together if they exceed the length).
    static func normalize(_ c: inout AudioClip) {
        c.volume = c.volume.isFinite ? max(0, min(1, c.volume)) : 1
        c.fileOffset = c.fileOffset.isFinite ? max(0, c.fileOffset) : 0
        clampFades(&c, fadeIn: c.fadeIn, fadeOut: c.fadeOut, keep: .fadeIn)
    }

    enum Fade { case fadeIn, fadeOut }

    /// Sets both fades; if their sum exceeds the length, the one not named in `keep` gives way first.
    private static func clampFades(_ c: inout AudioClip, fadeIn: Double, fadeOut: Double, keep: Fade) {
        let len = max(c.end - c.start, 0)
        var i = fadeIn.isFinite ? max(0, fadeIn) : 0
        var o = fadeOut.isFinite ? max(0, fadeOut) : 0
        switch keep {
        case .fadeIn: i = min(i, len); o = min(o, len - i)
        case .fadeOut: o = min(o, len); i = min(i, len - o)
        }
        c.fadeIn = i; c.fadeOut = o
    }

    /// A new clip of `length` seconds at the playhead, moved back near the end of the video so it keeps its length.
    /// nil when the video is shorter than `minLength` or the playhead is not finite. Never looks at other clips.
    static func add(_ clips: [AudioClip], at playhead: Double, length: Double = defaultLength, duration: Double,
                    make: (Double, Double) -> AudioClip = { AudioClip(start: $0, end: $1) }) -> (clips: [AudioClip], added: AudioClip)? {
        guard duration >= minLength, playhead.isFinite else { return nil }
        var start = max(0, min(playhead, duration))
        if start + length > duration { start = max(0, duration - length) }
        let end = min(start + length, duration)
        guard end - start >= minLength - 1e-9 else { return nil }
        var c = make(start, end)
        normalize(&c)
        return (sorted(clips + [c]), c)
    }

    /// Sets both times (numeric fields). nil when invalid: not finite, outside the video or shorter than `minLength`.
    /// Fades are re-clamped to the new length.
    static func setRange(_ clips: [AudioClip], id: UUID, start: Double, end: Double, duration: Double) -> [AudioClip]? {
        guard let i = clips.firstIndex(where: { $0.id == id }), start.isFinite, end.isFinite,
              start >= 0, end <= duration + 1e-9, end - start >= minLength - 1e-9 else { return nil }
        var out = clips
        out[i].start = start
        out[i].end = min(end, duration)
        normalize(&out[i])
        return sorted(out)
    }

    /// Moves one edge for dragging; it stops at the video ends and `minLength` from the other edge, so it never fails.
    /// Only the edge moves: the file offset ("File start") is its own setting and is never changed by dragging.
    static func moveEdge(_ clips: [AudioClip], id: UUID, edge: RegionEdit.Edge, to time: Double, duration: Double) -> [AudioClip] {
        guard let i = clips.firstIndex(where: { $0.id == id }), time.isFinite else { return clips }
        var out = clips
        let c = clips[i]
        switch edge {
        case .start:
            out[i].start = max(0, min(time, c.end - minLength))
        case .end:
            out[i].end = min(duration, max(time, c.start + minLength))
        }
        normalize(&out[i])
        return out   // order is by start; not re-sorted while dragging so the dragged clip keeps its identity in the UI
    }

    /// Moves a whole clip so that it starts at `start` for dragging: same length, same `fileOffset` (the same part of the
    /// file plays at the new place), clamped inside the video. Overlapping other clips is fine.
    static func move(_ clips: [AudioClip], id: UUID, toStart start: Double, duration: Double) -> [AudioClip] {
        guard let i = clips.firstIndex(where: { $0.id == id }), start.isFinite else { return clips }
        var out = clips
        let c = clips[i]
        let length = c.end - c.start
        guard length <= duration else { return clips }
        let s = max(0, min(start, duration - length))
        out[i].start = s
        out[i].end = s + length
        return out
    }

    static func setFileOffset(_ clips: [AudioClip], id: UUID, to offset: Double) -> [AudioClip]? {
        guard let i = clips.firstIndex(where: { $0.id == id }), offset.isFinite, offset >= 0 else { return nil }
        var out = clips
        out[i].fileOffset = offset
        return out
    }

    /// Sets the fades; if the sum exceeds the clip length the one named in `keep` wins.
    static func setFades(_ clips: [AudioClip], id: UUID, fadeIn: Double, fadeOut: Double, keep: Fade = .fadeIn) -> [AudioClip]? {
        guard let i = clips.firstIndex(where: { $0.id == id }), fadeIn.isFinite, fadeOut.isFinite else { return nil }
        var out = clips
        clampFades(&out[i], fadeIn: fadeIn, fadeOut: fadeOut, keep: keep)
        return out
    }

    static func setVolume(_ clips: [AudioClip], id: UUID, to volume: Double) -> [AudioClip]? {
        guard let i = clips.firstIndex(where: { $0.id == id }), volume.isFinite else { return nil }
        var out = clips
        out[i].volume = max(0, min(1, volume))
        return out
    }

    /// Stable order by start (equal starts keep their order, so later-added clips stay later).
    static func sorted(_ clips: [AudioClip]) -> [AudioClip] {
        clips.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
    }
}
