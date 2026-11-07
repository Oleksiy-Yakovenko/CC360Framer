import XCTest
import AVFoundation
@testable import CCAppCore

final class AudioClipPlaybackTests: XCTestCase {
    private let sync = AudioClipSync()

    private func acts(main: Double, playing: Bool = true, running: Bool = true, scrub: Bool = false, clip: Double,
                      clipPlaying: Bool = true, rate: Double = 1, dur: Double = 100) -> [AudioClipSync.Action] {
        sync.actions(mainTime: main, mainPlaying: playing, mainRunning: running, scrubbing: scrub, clipTime: clip,
                     clipPlaying: clipPlaying, clipRate: rate, clipDuration: dur)
    }

    func testInSyncDoesNothing() {
        XCTAssertEqual(acts(main: 10, clip: 10.02), [])
        XCTAssertEqual(acts(main: 10, clip: 9.98), [])
    }
    func testSmallDriftNudgesRateInsteadOfSeeking() {
        XCTAssertEqual(acts(main: 10, clip: 10.2), [.setRate(0.96)])    // ahead: slow down
        XCTAssertEqual(acts(main: 10, clip: 9.8), [.setRate(1.04)])     // behind: speed up
        XCTAssertEqual(acts(main: 10, clip: 9.8, rate: 1.04), [])       // already nudging
    }
    func testHysteresisKeepsNudgingUntilSettled() {
        // 0.02 behind is inside okDrift but outside settledDrift while nudging: keep the (right) direction.
        XCTAssertEqual(acts(main: 10, clip: 9.98, rate: 1.04), [])
        XCTAssertEqual(acts(main: 10, clip: 9.995, rate: 1.04), [.setRate(1)])
    }
    func testBigDriftSeeksAheadOfTarget() {
        XCTAssertEqual(acts(main: 10, clip: 11), [.seek(10.05)])
        XCTAssertEqual(acts(main: 10, clip: 3, rate: 1.04), [.seek(10.05), .setRate(1)])
    }
    func testClassify() {
        XCTAssertEqual(sync.classify(drift: 0.01, nudging: false), .ok)
        XCTAssertEqual(sync.classify(drift: -0.1, nudging: false), .nudge(rate: 1.04))
        XCTAssertEqual(sync.classify(drift: 0.1, nudging: false), .nudge(rate: 0.96))
        XCTAssertEqual(sync.classify(drift: 0.6, nudging: true), .seek)
        XCTAssertEqual(sync.classify(drift: -0.6, nudging: false), .seek)
        XCTAssertEqual(sync.classify(drift: 0.02, nudging: true), .nudge(rate: 0.96))
    }
    func testStartsWhenStoppedAtTargetPlusLead() {
        XCTAssertEqual(acts(main: 10, clip: 10, clipPlaying: false), [.start(at: 10.05)])
        XCTAssertEqual(acts(main: 10, clip: 3, clipPlaying: false), [.start(at: 10.05)])
        XCTAssertEqual(acts(main: 99.99, clip: 3, clipPlaying: false), [.start(at: 100)])
    }
    func testWaitsWhileMainIsNotReallyRunning() {
        // Main wants to play but is still buffering / seeking: the clip stays paused at the target, never starts early.
        XCTAssertEqual(acts(main: 10, running: false, clip: 10, clipPlaying: false), [])
        XCTAssertEqual(acts(main: 10, running: false, clip: 4, clipPlaying: false), [.seek(10)])
        XCTAssertEqual(acts(main: 10, running: false, clip: 10), [.pause])
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

    /// Regression: after a seek the clip player used to be re-seeked (restarting its audio) on every check because a
    /// 0.1 s lag exceeded the old 0.08 s threshold; a lag like that is now only a rate nudge, never a seek.
    func testModerateLagNeverSeeks() {
        for lag in stride(from: 0.04, through: 0.45, by: 0.01) {
            let a = acts(main: 30, clip: 30 - lag)
            XCTAssertFalse(a.contains { if case .seek = $0 { return true } else { return false } }, "lag \(lag)")
        }
    }

    func testNeedsRebuild() {
        let a = AudioClip(path: "/a.wav", start: 1, end: 5, fileOffset: 2, fadeIn: 0, fadeOut: 0, volume: 1)
        var b = a
        b.volume = 0.3; b.fadeIn = 1; b.fadeOut = 0.5
        XCTAssertFalse(AudioClipSync.needsRebuild(old: [a], new: [b]))
        for change in [{ (c: inout AudioClip) in c.path = "/b.wav" }, { $0.start = 1.5 }, { $0.end = 6 }, { $0.fileOffset = 3 }] {
            var c = a; change(&c)
            XCTAssertTrue(AudioClipSync.needsRebuild(old: [a], new: [c]))
        }
        XCTAssertTrue(AudioClipSync.needsRebuild(old: [a], new: [a, b]))
        var other = a; other.id = UUID()
        XCTAssertTrue(AudioClipSync.needsRebuild(old: [a], new: [other]))
    }

    func testPiecesMatchIgnoresVolumes() {
        let id = UUID()
        let p = AudioMixPlan.Piece(clipID: id, path: "/a", fileStart: 1, outputStart: 2, length: 3, volumes: [.init(time: 2, volume: 1), .init(time: 5, volume: 1)])
        var q = p; q.volumes = [.init(time: 2, volume: 0.2), .init(time: 5, volume: 0.5)]
        XCTAssertTrue(AudioClipSync.piecesMatch([p], [q]))
        q.length = 2.5
        XCTAssertFalse(AudioClipSync.piecesMatch([p], [q]))
        XCTAssertFalse(AudioClipSync.piecesMatch([p], []))
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

    /// A volume / fade edit re-plans the mix on the same composition (no rebuild).
    func testRemixKeepsCompositionForVolumeChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clipplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 8000, n = rate * 4
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        d.append(Data(count: n * 2))
        let url = dir.appendingPathComponent("a.wav")
        try d.write(to: url)
        var clip = AudioClip(path: url.path, start: 1, end: 4)
        let built = try XCTUnwrap(try AudioExport.build(source: nil, trackIDs: [], map: nil, sourceDuration: 10, clips: [clip]))
        XCTAssertEqual(built.pieces.count, 1)
        clip.volume = 0.4; clip.fadeIn = 1
        let mix = AudioExport.remix(built, clips: [clip], sourceDuration: 10)
        XCTAssertEqual(mix?.inputParameters.count, 1)
        clip.start = 2   // placement changed: the composition no longer fits
        XCTAssertNil(AudioExport.remix(built, clips: [clip], sourceDuration: 10))
    }
}
