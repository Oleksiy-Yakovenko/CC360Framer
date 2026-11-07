import XCTest
@testable import CCAppCore

final class AudioMixPlanTests: XCTestCase {
    private func clip(_ s: Double, _ e: Double, offset: Double = 0, fi: Double = 0, fo: Double = 0, vol: Double = 1, path: String = "/a.wav") -> AudioClip {
        AudioClip(path: path, start: s, end: e, fileOffset: offset, fadeIn: fi, fadeOut: fo, volume: vol)
    }
    private func ok(_ d: Double? = nil) -> (AudioClip) -> AudioFileInfo? { { _ in AudioFileInfo(exists: true, duration: d, hasAudio: true) } }
    private func vol(_ p: AudioMixPlan.Piece, at t: Double) -> Double {
        // linear interpolation of the breakpoints, as the mix applies them
        let v = p.volumes
        guard let i = v.indices.dropLast().first(where: { v[$0].time <= t && t <= v[$0 + 1].time }) else { return v.last?.volume ?? 0 }
        let (a, b) = (v[i], v[i + 1])
        return b.time == a.time ? b.volume : a.volume + (b.volume - a.volume) * (t - a.time) / (b.time - a.time)
    }

    func testNoCutsOnePiece() {
        let c = clip(2, 6, offset: 1.5, fi: 1, fo: 1, vol: 0.5)
        let r = AudioMixPlan.make(clips: [c], duration: 10, map: nil, info: ok())
        XCTAssertEqual(r.pieces.count, 1)
        let p = r.pieces[0]
        XCTAssertEqual(p.outputStart, 2); XCTAssertEqual(p.length, 4); XCTAssertEqual(p.fileStart, 1.5)
        XCTAssertEqual(p.volumes.first, AudioMixPlan.Point(time: 2, volume: 0))
        XCTAssertEqual(p.volumes.last, AudioMixPlan.Point(time: 6, volume: 0))
        XCTAssertEqual(vol(p, at: 3), 0.5, accuracy: 1e-9)
        XCTAssertEqual(vol(p, at: 2.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(vol(p, at: 5.5), 0.25, accuracy: 1e-9)
        XCTAssertTrue(r.skipped.isEmpty)
    }

    func testCutInMiddleOfClip() {
        let m = TimeMap(cuts: [CutRegion(start: 4, end: 6)], duration: 10)
        let r = AudioMixPlan.make(clips: [clip(2, 8, offset: 1)], duration: 10, map: m, info: ok())
        XCTAssertEqual(r.pieces.count, 2)
        // The music jumps with the video: the second piece starts at file position 1 + (6 - 2).
        XCTAssertEqual(r.pieces[0].fileStart, 1); XCTAssertEqual(r.pieces[0].outputStart, 2); XCTAssertEqual(r.pieces[0].length, 2)
        XCTAssertEqual(r.pieces[1].fileStart, 5); XCTAssertEqual(r.pieces[1].outputStart, 4); XCTAssertEqual(r.pieces[1].length, 2)
    }

    func testClipInsideCutIsDropped() {
        let m = TimeMap(cuts: [CutRegion(start: 2, end: 8)], duration: 10)
        let r = AudioMixPlan.make(clips: [clip(3, 6)], duration: 10, map: m, info: ok())
        XCTAssertTrue(r.pieces.isEmpty)
        XCTAssertTrue(r.skipped.isEmpty)   // dropped by the cut, not unusable
    }

    func testFadeContinuesAcrossCut() {
        // Fade-out 4 s at the end of a clip 0...10, cut 7...9: the second piece continues the fade, it does not restart.
        let m = TimeMap(cuts: [CutRegion(start: 7, end: 9)], duration: 10)
        let c = clip(0, 10, fo: 4)
        let r = AudioMixPlan.make(clips: [c], duration: 10, map: m, info: ok())
        XCTAssertEqual(r.pieces.count, 2)
        // First piece ends at source 7: gain 3/4; the second begins at source 9 (output 7): gain 1/4.
        XCTAssertEqual(r.pieces[0].volumes.last!.volume, 0.75, accuracy: 1e-9)
        XCTAssertEqual(r.pieces[1].volumes.first!.volume, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.pieces[1].volumes.last!.volume, 0, accuracy: 1e-9)
        XCTAssertEqual(r.pieces[1].outputStart, 7)
    }

    func testDissolveRampsOnPieces() {
        // Cut 4...6 with 1 s crossfade: segments [0,4] and [6,10], second starts at output 3.
        let m = TimeMap(cuts: [CutRegion(start: 4, end: 6)], duration: 10, crossfade: 1)
        let r = AudioMixPlan.make(clips: [clip(0, 10)], duration: 10, map: m, info: ok())
        XCTAssertEqual(r.pieces.count, 2)
        let (a, b) = (r.pieces[0], r.pieces[1])
        XCTAssertEqual(a.outputEnd, 4); XCTAssertEqual(b.outputStart, 3)
        XCTAssertEqual(vol(a, at: 2), 1, accuracy: 1e-9)
        XCTAssertEqual(vol(a, at: 3), 1, accuracy: 1e-9)
        XCTAssertEqual(vol(a, at: 3.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(vol(a, at: 4), 0, accuracy: 1e-9)
        XCTAssertEqual(vol(b, at: 3), 0, accuracy: 1e-9)
        XCTAssertEqual(vol(b, at: 3.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(vol(b, at: 4), 1, accuracy: 1e-9)
        XCTAssertEqual(b.fileStart, 6)
    }

    func testClipLongerThanFileIsShortened() {
        let r = AudioMixPlan.make(clips: [clip(1, 9, offset: 2)], duration: 10, map: nil, info: ok(5))
        XCTAssertEqual(r.pieces.count, 1)
        XCTAssertEqual(r.pieces[0].length, 3, accuracy: 1e-9)
        XCTAssertEqual(r.pieces[0].volumes.last!.time, 4, accuracy: 1e-9)
        // Offset beyond the file: nothing to play.
        XCTAssertTrue(AudioMixPlan.make(clips: [clip(1, 9, offset: 5)], duration: 10, map: nil, info: ok(5)).pieces.isEmpty)
    }

    func testOverlappingClipsGiveSeparatePieces() {
        let r = AudioMixPlan.make(clips: [clip(0, 5, vol: 0.5), clip(2, 7, vol: 0.25, path: "/b.wav")], duration: 10, map: nil, info: ok())
        XCTAssertEqual(r.pieces.count, 2)
        XCTAssertEqual(r.pieces.map(\.path), ["/a.wav", "/b.wav"])
        XCTAssertEqual(r.pieces[0].volumes.map(\.volume), [0.5, 0.5])
    }

    func testClipBeforeZeroAndAfterEnd() {
        var c = AudioClip(path: "/a.wav", start: -2, end: 12, fileOffset: 1)
        c.start = -2; c.end = 12   // the editing rules never produce this, a hand-edited sidecar could
        let r = AudioMixPlan.make(clips: [c], duration: 10, map: nil, info: ok())
        XCTAssertEqual(r.pieces.count, 1)
        XCTAssertEqual(r.pieces[0].outputStart, 0); XCTAssertEqual(r.pieces[0].length, 10)
        XCTAssertEqual(r.pieces[0].fileStart, 3)   // 1 + (0 - (-2))
    }

    func testUnusableClipsAreSkipped() {
        let good = clip(0, 2), noPath = clip(0, 2, path: ""), missing = clip(0, 2, path: "/m.wav"), silent = clip(0, 2, path: "/s.wav")
        let r = AudioMixPlan.make(clips: [good, noPath, missing, silent], duration: 10, map: nil) { c in
            switch c.path {
            case "/a.wav": return AudioFileInfo(exists: true, duration: 5, hasAudio: true)
            case "/s.wav": return AudioFileInfo(exists: true, duration: nil, hasAudio: false)
            default: return nil
            }
        }
        XCTAssertEqual(r.pieces.count, 1)
        XCTAssertEqual(Set(r.skipped), [noPath.id, missing.id, silent.id])
    }

    func testZeroLengthPiecesDropped() {
        let m = TimeMap(cuts: [CutRegion(start: 4, end: 6)], duration: 10)
        // Clip ends exactly where the cut starts: only one piece, no empty second one.
        XCTAssertEqual(AudioMixPlan.make(clips: [clip(1, 4)], duration: 10, map: m, info: ok()).pieces.count, 1)
        XCTAssertTrue(AudioMixPlan.make(clips: [clip(4, 4.0004)], duration: 10, map: nil, info: ok()).pieces.isEmpty)
    }
}
