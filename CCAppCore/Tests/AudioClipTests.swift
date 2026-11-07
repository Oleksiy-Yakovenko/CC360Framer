import XCTest
@testable import CCAppCore

final class AudioClipTests: XCTestCase {
    private func clip(_ s: Double, _ e: Double, offset: Double = 0, fi: Double = 0, fo: Double = 0, vol: Double = 1) -> AudioClip {
        AudioClip(path: "/a.m4a", start: s, end: e, fileOffset: offset, fadeIn: fi, fadeOut: fo, volume: vol)
    }

    func testInitClamps() {
        let c = clip(0, 4, offset: -3, fi: 3, fo: 3, vol: 2)
        XCTAssertEqual(c.fileOffset, 0)
        XCTAssertEqual(c.volume, 1)
        XCTAssertEqual(c.fadeIn, 3); XCTAssertEqual(c.fadeOut, 1)   // fade in kept, fade out gives way
    }

    func testAddAtPlayheadAllowsOverlap() {
        let existing = [clip(4, 9)]
        let r = AudioClipEdit.add(existing, at: 5, duration: 20)!
        XCTAssertEqual(r.added.start, 5); XCTAssertEqual(r.added.end, 8)
        XCTAssertEqual(r.clips.count, 2)
    }

    func testAddClampsAtEnds() {
        let near = AudioClipEdit.add([], at: 19, duration: 20)!.added
        XCTAssertEqual(near.end, 20); XCTAssertEqual(near.start, 17)
        let neg = AudioClipEdit.add([], at: -5, duration: 20)!.added
        XCTAssertEqual(neg.start, 0)
        let short = AudioClipEdit.add([], at: 0, duration: 1)!.added
        XCTAssertEqual(short.start, 0); XCTAssertEqual(short.end, 1)
        XCTAssertNil(AudioClipEdit.add([], at: 0, duration: 0.1))
        XCTAssertNil(AudioClipEdit.add([], at: .nan, duration: 10))
    }

    func testSetRangeValidatesAndReclampsFades() {
        let c = clip(2, 8, fi: 2, fo: 3)
        XCTAssertNil(AudioClipEdit.setRange([c], id: c.id, start: 5, end: 5.1, duration: 20))
        XCTAssertNil(AudioClipEdit.setRange([c], id: c.id, start: -1, end: 5, duration: 20))
        XCTAssertNil(AudioClipEdit.setRange([c], id: c.id, start: 5, end: 21, duration: 20))
        XCTAssertNil(AudioClipEdit.setRange([c], id: c.id, start: .nan, end: 5, duration: 20))
        XCTAssertNil(AudioClipEdit.setRange([c], id: UUID(), start: 1, end: 5, duration: 20))
        let out = AudioClipEdit.setRange([c], id: c.id, start: 2, end: 4, duration: 20)![0]
        XCTAssertEqual(out.fadeIn, 2); XCTAssertEqual(out.fadeOut, 0)
        // overlapping another clip is fine
        let other = clip(0, 10)
        XCTAssertNotNil(AudioClipEdit.setRange([other, c], id: c.id, start: 1, end: 9, duration: 20))
    }

    func testSetRangeSorts() {
        let a = clip(0, 3), b = clip(5, 8)
        let out = AudioClipEdit.setRange([a, b], id: a.id, start: 10, end: 12, duration: 20)!
        XCTAssertEqual(out.map(\.id), [b.id, a.id])
    }

    func testMoveEndEdge() {
        let c = clip(2, 6)
        XCTAssertEqual(AudioClipEdit.moveEdge([c], id: c.id, edge: .end, to: 100, duration: 20)[0].end, 20)
        XCTAssertEqual(AudioClipEdit.moveEdge([c], id: c.id, edge: .end, to: 0, duration: 20)[0].end, 2 + AudioClipEdit.minLength, accuracy: 1e-9)
    }

    func testMoveStartEdgeKeepsAudioInPlace() {
        let c = clip(4, 10, offset: 1)
        let later = AudioClipEdit.moveEdge([c], id: c.id, edge: .start, to: 6, duration: 20)[0]
        XCTAssertEqual(later.start, 6); XCTAssertEqual(later.fileOffset, 3, accuracy: 1e-9)
        // dragging left can only reveal the audio that exists before the offset
        let earlier = AudioClipEdit.moveEdge([c], id: c.id, edge: .start, to: 0, duration: 20)[0]
        XCTAssertEqual(earlier.start, 3, accuracy: 1e-9); XCTAssertEqual(earlier.fileOffset, 0, accuracy: 1e-9)
        // never past the end
        let past = AudioClipEdit.moveEdge([c], id: c.id, edge: .start, to: 50, duration: 20)[0]
        XCTAssertEqual(past.start, 10 - AudioClipEdit.minLength, accuracy: 1e-9)
    }

    func testMoveEdgeKeepsFadesValid() {
        let c = clip(0, 6, fi: 2, fo: 3)
        let out = AudioClipEdit.moveEdge([c], id: c.id, edge: .end, to: 3, duration: 20)[0]
        XCTAssertLessThanOrEqual(out.fadeIn + out.fadeOut, out.end - out.start + 1e-9)
    }

    func testFileOffsetFadesVolume() {
        let c = clip(0, 4)
        XCTAssertNil(AudioClipEdit.setFileOffset([c], id: c.id, to: -1))
        XCTAssertEqual(AudioClipEdit.setFileOffset([c], id: c.id, to: 12)![0].fileOffset, 12)
        let f = AudioClipEdit.setFades([c], id: c.id, fadeIn: 3, fadeOut: 3)![0]
        XCTAssertEqual(f.fadeIn, 3); XCTAssertEqual(f.fadeOut, 1)
        let g = AudioClipEdit.setFades([c], id: c.id, fadeIn: 3, fadeOut: 3, keep: .fadeOut)![0]
        XCTAssertEqual(g.fadeOut, 3); XCTAssertEqual(g.fadeIn, 1)
        XCTAssertEqual(AudioClipEdit.setFades([c], id: c.id, fadeIn: -1, fadeOut: 9)![0].fadeOut, 4)
        XCTAssertEqual(AudioClipEdit.setVolume([c], id: c.id, to: 5)![0].volume, 1)
        XCTAssertEqual(AudioClipEdit.setVolume([c], id: c.id, to: -5)![0].volume, 0)
        XCTAssertNil(AudioClipEdit.setVolume([c], id: c.id, to: .infinity))
    }

    func testGain() {
        let c = clip(10, 20, fi: 2, fo: 2, vol: 0.5)
        XCTAssertEqual(c.gain(at: 9), 0); XCTAssertEqual(c.gain(at: 20), 0)
        XCTAssertEqual(c.gain(at: 11), 0.25, accuracy: 1e-9)
        XCTAssertEqual(c.gain(at: 15), 0.5, accuracy: 1e-9)
        XCTAssertEqual(c.gain(at: 19), 0.25, accuracy: 1e-9)
    }

    func testCodableRoundTripAndLenientDecoding() throws {
        let c = clip(1, 5, offset: 2, fi: 1, fo: 0.5, vol: 0.7)
        let back = try JSONDecoder().decode(AudioClip.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
        let minimal = try JSONDecoder().decode(AudioClip.self, from: Data(#"{"start":1,"end":4,"volume":"loud","fadeIn":9}"#.utf8))
        XCTAssertEqual(minimal.path, ""); XCTAssertEqual(minimal.volume, 1); XCTAssertEqual(minimal.fadeIn, 3)
        XCTAssertThrowsError(try JSONDecoder().decode(AudioClip.self, from: Data(#"{"start":1}"#.utf8)))
    }

    func testProjectSidecarRoundTripAndOldFile() throws {
        let c = clip(1, 5)
        var p = ProjectSidecar()
        p.audioClips = [c]
        let back = ProjectSidecar.decode(p.encoded()!)!
        XCTAssertEqual(back.audioClips, [c])
        let old = ProjectSidecar.decode(Data(#"{"captions":[{"start":1,"end":2}]}"#.utf8))!
        XCTAssertNil(old.audioClips)
        XCTAssertEqual(old.captions?.count, 1)
    }

    func testTimelineKindAndHitTesting() {
        XCTAssertTrue(TimelineKind.audio.isRegion)
        XCTAssertEqual(TimelineKind.audio.rawValue, "Audio")
        let l = TimelineLayout(width: 1000, duration: 100)   // 10 px per second
        let a = TimelineItem(id: UUID(), start: 10, end: 50), b = TimelineItem(id: UUID(), start: 20, end: 60)
        let px = l.x(30)
        XCTAssertEqual(l.hit([a, b], selected: nil, at: px), .region(b.id))   // latest wins
        XCTAssertEqual(l.hit([a, b], selected: a.id, at: px), .region(a.id))  // selected wins
        XCTAssertEqual(l.hit([a, b], selected: a.id, at: l.x(55)), .region(b.id))   // selected does not contain it
        XCTAssertEqual(l.hit([a, b], selected: nil, at: l.x(20)), .regionStart(b.id))
        let same = TimelineItem(id: UUID(), start: 10, end: 40)
        XCTAssertEqual(l.hit([a, same], selected: nil, at: l.x(10)), .regionStart(same.id))   // tie: later
    }
}
