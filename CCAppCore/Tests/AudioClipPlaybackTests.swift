import XCTest
import AVFoundation
@testable import CCAppCore

final class AudioClipPlaybackTests: XCTestCase {
    private let sync = AudioClipSync()

    private func acts(main: Double, playing: Bool = true, scrub: Bool = false, clip: Double, clipPlaying: Bool = true,
                      dur: Double = 100) -> [AudioClipSync.Action] {
        sync.actions(mainTime: main, mainPlaying: playing, scrubbing: scrub, clipTime: clip, clipPlaying: clipPlaying, clipDuration: dur)
    }

    func testInSyncDoesNothing() {
        XCTAssertEqual(acts(main: 10, clip: 10.05), [])
    }
    func testDriftReseeks() {
        XCTAssertEqual(acts(main: 10, clip: 10.2), [.seek(10)])
        XCTAssertEqual(acts(main: 10, clip: 9.8), [.seek(10)])
    }
    func testStartsWhenStopped() {
        XCTAssertEqual(acts(main: 10, clip: 10, clipPlaying: false), [.play])
        XCTAssertEqual(acts(main: 10, clip: 3, clipPlaying: false), [.seek(10), .play])
    }
    func testPausedMainPausesClip() {
        XCTAssertEqual(acts(main: 10, playing: false, clip: 10), [.pause])
        XCTAssertEqual(acts(main: 10, playing: false, clip: 4, clipPlaying: false), [.seek(10)])
        XCTAssertEqual(acts(main: 10, playing: false, clip: 10, clipPlaying: false), [])
    }
    func testScrubbingIsSilent() {
        XCTAssertEqual(acts(main: 20, scrub: true, clip: 10), [.pause, .seek(20)])
    }
    func testPastTheEndPauses() {
        XCTAssertEqual(acts(main: 120, clip: 100), [.pause])
        XCTAssertEqual(acts(main: 120, clip: 100, clipPlaying: false), [])
    }
    func testNoItemNoActions() {
        XCTAssertEqual(acts(main: 1, clip: 0, dur: 0), [])
    }
    func testRebuildGateDropsStale() {
        var g = RebuildGate()
        let a = g.request()
        let b = g.request()
        XCTAssertFalse(g.isCurrent(a))
        XCTAssertTrue(g.isCurrent(b))
    }

    /// The preview item is built like the export's clips-only mix: one track per clip piece, source timeline length.
    func testPreviewItemFromGeneratedWav() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 48000, n = rate * 4
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        for i in 0..<n { u16(UInt16(bitPattern: Int16(8000 * sin(2 * .pi * 440 * Double(i) / Double(rate))))) }
        let url = dir.appendingPathComponent("a.wav")
        try d.write(to: url)
        let clip = AudioClip(path: url.path, start: 1, end: 4)
        let built = try XCTUnwrap(try AudioExport.build(source: nil, trackIDs: [], map: nil, sourceDuration: 10, clips: [clip]))
        XCTAssertEqual(built.tracks.count, 1)
        XCTAssertEqual(built.composition.tracks(withMediaType: .audio).count, 1)
        XCTAssertGreaterThanOrEqual(built.composition.duration.seconds, 3.9)
        XCTAssertLessThanOrEqual(built.composition.duration.seconds, 10.01)
        XCTAssertNil(try AudioExport.build(source: nil, trackIDs: [], map: nil, sourceDuration: 10, clips: []))
    }
}
