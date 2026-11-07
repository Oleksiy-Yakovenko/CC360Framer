import XCTest
import AVFoundation
@testable import CCAppCore

/// Offline tests of the audio composition + mix the export reads (no .360, no export): small WAV files are mixed and
/// the result is read back through the same AVAssetReaderAudioMixOutput the Exporter uses.
final class AudioExportTests: XCTestCase {
    private let rate = 48000
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("audioexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Mono 16-bit 48 kHz 440 Hz sine whose amplitude is `amp(t)`.
    private func writeWav(_ name: String, seconds: Double, amp: (Double) -> Double) throws -> URL {
        let n = Int(seconds * Double(rate))
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            let v = Int16((amp(t) * sin(2 * .pi * 440 * t) * 32767).rounded())
            u16(UInt16(bitPattern: v))
        }
        let url = dir.appendingPathComponent(name)
        try d.write(to: url)
        return url
    }

    /// Reads the mix back as mono float samples placed by their time stamps (gaps stay 0).
    private func render(_ built: AudioExport.Built, seconds: Double) throws -> [Float] {
        let reader = try AVAssetReader(asset: built.composition)
        let out = AVAssetReaderAudioMixOutput(audioTracks: built.tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1])
        out.audioMix = built.mix
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var samples = [Float](repeating: 0, count: Int(seconds * Double(rate)))
        while let sb = out.copyNextSampleBuffer() {
            let start = Int((CMSampleBufferGetPresentationTimeStamp(sb).seconds * Double(rate)).rounded())
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMSampleBufferGetNumSamples(sb)
            var data = [Float](repeating: 0, count: n)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: &data)
            for i in 0..<n where start + i >= 0 && start + i < samples.count { samples[start + i] = data[i] }
        }
        return samples
    }

    private func rms(_ s: [Float], _ a: Double, _ b: Double) -> Double {
        let r = s[Int(a * Double(rate))..<min(Int(b * Double(rate)), s.count)]
        return (r.reduce(0.0) { $0 + Double($1 * $1) } / Double(r.count)).squareRoot()
    }

    func testSingleClipWithOffsetFadesAndVolume() throws {
        let url = try writeWav("a.wav", seconds: 3) { _ in 0.5 }
        let clip = AudioClip(path: url.path, start: 1, end: 3, fileOffset: 0.5, fadeIn: 0.5, fadeOut: 0.5, volume: 0.5)
        let built = try XCTUnwrap(AudioExport.build(source: nil, trackIDs: [], map: nil, sourceDuration: 4, clips: [clip]))
        XCTAssertEqual(built.skipped, 0)
        let s = try render(built, seconds: 4)
        let full = 0.5 * 0.5 / 2.0.squareRoot()   // sine amplitude 0.5 x volume 0.5
        XCTAssertEqual(rms(s, 0, 0.9), 0, accuracy: 1e-4)                    // silence before
        XCTAssertEqual(rms(s, 1.6, 2.4), full, accuracy: full * 0.03)        // middle
        XCTAssertEqual(rms(s, 1.0, 1.5), full / 3.0.squareRoot(), accuracy: full * 0.06)   // linear ramp: mean square 1/3
        XCTAssertEqual(rms(s, 2.5, 3.0), full / 3.0.squareRoot(), accuracy: full * 0.06)
        XCTAssertLessThan(rms(s, 1.0, 1.02), full * 0.2)                      // starts from silence
        XCTAssertEqual(rms(s, 3.1, 4), 0, accuracy: 1e-4)                    // silence after
    }

    func testOverlappingClipsAreSummed() throws {
        let url = try writeWav("a.wav", seconds: 4) { _ in 0.5 }
        let a = AudioClip(path: url.path, start: 0, end: 3, volume: 0.5)
        let b = AudioClip(path: url.path, start: 1, end: 4, fileOffset: 1, volume: 0.25)   // same phase as `a` at the same time
        let built = try XCTUnwrap(AudioExport.build(source: nil, trackIDs: [], map: nil, sourceDuration: 4, clips: [a, b]))
        let s = try render(built, seconds: 4)
        let one = 0.5 / 2.0.squareRoot()
        XCTAssertEqual(rms(s, 0.2, 0.8), one * 0.5, accuracy: one * 0.03)
        XCTAssertEqual(rms(s, 1.2, 2.8), one * 0.75, accuracy: one * 0.03)
        XCTAssertEqual(rms(s, 3.2, 3.8), one * 0.25, accuracy: one * 0.03)
    }

    func testCutMakesTheMusicJumpWithTheVideo() throws {
        // File: amplitude 0.2 for the first 3 s, 0.8 afterwards. Cut 2...3 of a 6 s video.
        let url = try writeWav("step.wav", seconds: 6) { $0 < 3 ? 0.2 : 0.8 }
        let clip = AudioClip(path: url.path, start: 0, end: 6)
        let map = TimeMap(cuts: [CutRegion(start: 2, end: 3)], duration: 6)
        let built = try XCTUnwrap(AudioExport.build(source: nil, trackIDs: [], map: map, sourceDuration: 6, clips: [clip]))
        let s = try render(built, seconds: 5)
        XCTAssertEqual(rms(s, 0.2, 1.8), 0.2 / 2.0.squareRoot(), accuracy: 0.005)
        XCTAssertEqual(rms(s, 2.1, 4.9), 0.8 / 2.0.squareRoot(), accuracy: 0.015)   // already the loud part right after the cut
    }

    func testMissingAndSilentFilesAreSkipped() throws {
        let good = try writeWav("a.wav", seconds: 1) { _ in 0.5 }
        let text = dir.appendingPathComponent("t.wav")
        try Data("not audio".utf8).write(to: text)
        let clips = [AudioClip(path: good.path, start: 0, end: 1),
                     AudioClip(path: dir.appendingPathComponent("nope.wav").path, start: 0, end: 1),
                     AudioClip(path: text.path, start: 0, end: 1),
                     AudioClip(path: "", start: 0, end: 1)]
        let built = try XCTUnwrap(AudioExport.build(source: nil, trackIDs: [], map: nil, sourceDuration: 2, clips: clips))
        XCTAssertEqual(built.skipped, 3)
        XCTAssertEqual(built.tracks.count, 1)
        let none = try AudioExport.build(source: nil, trackIDs: [], map: nil, sourceDuration: 2, clips: [clips[1]])
        XCTAssertNil(none)
    }

    func testSourceTracksWithCutAndClipTogether() async throws {
        // A source composition with one constant-level audio track, as the .360's audio track would be.
        let srcURL = try writeWav("src.wav", seconds: 4) { _ in 0.4 }
        let asset = AVURLAsset(url: srcURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let source = AVMutableComposition()
        let st = try XCTUnwrap(source.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try st.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 48000)), of: track, at: .zero)
        let id = st.trackID
        let musicURL = try writeWav("m.wav", seconds: 4) { _ in 0.2 }
        let map = TimeMap(cuts: [CutRegion(start: 1, end: 2)], duration: 4)

        // Source only, with cuts: 3 s long and at the source level (the old CutExport.audio behaviour).
        let only = try XCTUnwrap(AudioExport.build(source: source, trackIDs: [id], map: map, sourceDuration: 4, clips: []))
        let s1 = try render(only, seconds: 3)
        let src = 0.4 / 2.0.squareRoot()
        XCTAssertEqual(rms(s1, 0.1, 2.9), src, accuracy: src * 0.03)

        // Source disabled (no track ids), clip only: audio is still there.
        let clip = AudioClip(path: musicURL.path, start: 0, end: 4)
        let clipOnly = try XCTUnwrap(AudioExport.build(source: source, trackIDs: [], map: map, sourceDuration: 4, clips: [clip]))
        let s2 = try render(clipOnly, seconds: 3)
        XCTAssertEqual(rms(s2, 0.1, 2.9), 0.2 / 2.0.squareRoot(), accuracy: 0.005)

        // Both: the sum (same frequency and phase).
        let both = try XCTUnwrap(AudioExport.build(source: source, trackIDs: [id], map: map, sourceDuration: 4, clips: [clip]))
        let s3 = try render(both, seconds: 3)
        XCTAssertEqual(rms(s3, 0.1, 2.9), 0.6 / 2.0.squareRoot(), accuracy: 0.015)
    }

    func testDissolveHasNoBumpAtTheStartOfTheIncomingLane() async throws {
        let srcURL = try writeWav("src.wav", seconds: 4) { _ in 0.4 }
        let srcAsset = AVURLAsset(url: srcURL)
        let tracks = try await srcAsset.loadTracks(withMediaType: .audio)
        let source = AVMutableComposition()
        let st = try XCTUnwrap(source.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try st.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 48000)), of: try XCTUnwrap(tracks.first), at: .zero)
        let map = TimeMap(cuts: [CutRegion(start: 1, end: 2)], duration: 4, crossfade: 0.5)   // output 3.5 s, dissolve 0.5...1.0
        let built: AudioExport.Built
        do { built = try XCTUnwrap(AudioExport.build(source: source, trackIDs: [st.trackID], map: map, sourceDuration: 4, clips: [])) } catch { XCTFail("build: \(error)"); return }
        XCTAssertEqual(built.tracks.count, 2)
        let s: [Float]
        do { s = try render(built, seconds: 3.5) } catch { XCTFail("render: \(error)"); return }
        let level = 0.4 / 2.0.squareRoot()
        // Both lanes carry the same signal, so the two ramps sum to a constant level through the dissolve.
        for k in 0..<50 {
            let a = 0.45 + Double(k) * 0.011
            XCTAssertEqual(rms(s, a, a + 0.005), level, accuracy: level * 0.12, "at \(a)")
        }
    }
}
