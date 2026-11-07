import Foundation

/// Pure plan for mixing user audio clips into the export (no AVFoundation, see `AudioExport` for the glue).
///
/// Clips live on the SOURCE timeline, like captions and cuts. The export timeline is the source timeline minus the
/// cuts, so a clip is positioned by source time: after a cut the music JUMPS with the video (the part of the file that
/// belonged to the cut is skipped, it does not continue where it stopped). Each kept segment is intersected with
/// each clip and gives one `Piece`; the file position of a piece is `fileOffset + (pieceSourceStart - clip.start)`.
/// Fades and volume come from the clip's own envelope in source time, so a fade cut by a segment boundary simply
/// continues in the next piece. At a dissolve the incoming piece fades in and the outgoing piece fades out over the
/// crossfade, exactly like the source-audio lanes (`TimeMap.fades`).
enum AudioMixPlan {
    struct Piece: Equatable {
        var clipID: UUID
        var path: String
        /// Position inside the audio file, seconds.
        var fileStart: Double
        /// Start on the export (output) timeline, seconds.
        var outputStart: Double
        var length: Double
        /// Volume breakpoints in output time (absolute, first = outputStart, last = outputStart + length), linear in between.
        var volumes: [Point]
        var outputEnd: Double { outputStart + length }
    }

    struct Point: Equatable {
        var time: Double
        var volume: Double
    }

    struct Result: Equatable {
        var pieces: [Piece]
        /// Clips that could not be used (file missing, no audio track, empty path).
        var skipped: [UUID]
    }

    /// Shortest piece that is kept.
    static let minPieceLength = 1e-3

    /// Clip envelope in source time, closed at the end (unlike `AudioClip.gain`, which is 0 at `end`).
    static func envelope(_ c: AudioClip, at t: Double) -> Double {
        var g = c.volume
        if c.fadeIn > 0 { g *= max(0, min(1, (t - c.start) / c.fadeIn)) }
        if c.fadeOut > 0 { g *= max(0, min(1, (c.end - t) / c.fadeOut)) }
        return g
    }

    /// `info` reports the probed file (nil / unusable = skipped). `map` nil = no cuts (output time = source time).
    static func make(clips: [AudioClip], duration: Double, map: TimeMap?, info: (AudioClip) -> AudioFileInfo?) -> Result {
        let segments: [TimeMap.Segment] = map?.segments ?? [TimeMap.Segment(sourceStart: 0, sourceEnd: max(duration, 0), outputStart: 0)]
        let fades = map?.fades ?? []
        var pieces: [Piece] = []
        var skipped: [UUID] = []
        for clip in clips {
            guard !clip.path.isEmpty, let fi = info(clip), fi.isUsable else { skipped.append(clip.id); continue }
            for (i, seg) in segments.enumerated() {
                let a = max(seg.sourceStart, clip.start), b = min(seg.sourceEnd, clip.end)
                guard b - a >= minPieceLength else { continue }
                let fileStart = clip.fileOffset + (a - clip.start)
                var length = b - a
                if let d = fi.duration { length = min(length, d - fileStart) }
                guard length >= minPieceLength else { continue }
                let outStart = seg.outputStart + (a - seg.sourceStart)
                let outEnd = outStart + length
                // Dissolve window of this segment on the output timeline.
                let fadeIn = i > 0 ? (fades.indices.contains(i - 1) ? fades[i - 1] : 0) : 0
                let fadeOut = fades.indices.contains(i) ? fades[i] : 0
                func dissolve(_ t: Double) -> Double {
                    var g = 1.0
                    if fadeIn > 0 { g *= max(0, min(1, (t - seg.outputStart) / fadeIn)) }
                    if fadeOut > 0 { g *= max(0, min(1, (seg.outputEnd - t) / fadeOut)) }
                    return g
                }
                func value(_ t: Double) -> Double { envelope(clip, at: seg.sourceStart + (t - seg.outputStart)) * dissolve(t) }
                // Corners of both piecewise-linear factors inside the piece.
                var times: Set<Double> = [outStart, outEnd]
                var corners = [seg.outputStart + fadeIn, seg.outputEnd - fadeOut]
                corners += [clip.start + clip.fadeIn, clip.end - clip.fadeOut].map { seg.outputStart + ($0 - seg.sourceStart) }
                for c in corners where c > outStart + 1e-9 && c < outEnd - 1e-9 { times.insert(c) }
                let sorted = times.sorted()
                // Where both factors are sloped the product is curved; extra points keep the linear ramps close to it.
                var points: [Point] = []
                for (k, t) in sorted.enumerated() {
                    if k > 0 {
                        let p = sorted[k - 1]
                        let mid = (p + t) / 2
                        let slopedBoth = isSloped(clip: clip, seg: seg, fadeIn: fadeIn, fadeOut: fadeOut, mid: mid)
                        if slopedBoth {
                            for s in 1..<4 { let u = p + (t - p) * Double(s) / 4; points.append(Point(time: u, volume: value(u))) }
                        }
                    }
                    points.append(Point(time: t, volume: value(t)))
                }
                pieces.append(Piece(clipID: clip.id, path: clip.path, fileStart: fileStart, outputStart: outStart, length: length, volumes: points))
            }
        }
        return Result(pieces: pieces, skipped: skipped)
    }

    /// True when both the clip fades and the dissolve are changing at output time `mid`.
    private static func isSloped(clip: AudioClip, seg: TimeMap.Segment, fadeIn: Double, fadeOut: Double, mid: Double) -> Bool {
        let s = seg.sourceStart + (mid - seg.outputStart)
        let clipSloped = (clip.fadeIn > 0 && s < clip.start + clip.fadeIn) || (clip.fadeOut > 0 && s > clip.end - clip.fadeOut)
        let dissolveSloped = (fadeIn > 0 && mid < seg.outputStart + fadeIn) || (fadeOut > 0 && mid > seg.outputEnd - fadeOut)
        return clipSloped && dissolveSloped
    }
}
