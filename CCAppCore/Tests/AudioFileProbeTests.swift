import XCTest
@testable import CCAppCore

final class AudioFileProbeTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// Mono 16-bit 8 kHz PCM silence.
    private func wav(seconds: Double) -> Data {
        let rate: UInt32 = 8000, n = UInt32(seconds * Double(rate)), bytes = n * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes); d.append(Data(count: Int(bytes)))
        return d
    }

    func testProbeValidWav() async throws {
        let url = dir.appendingPathComponent("a.wav")
        try wav(seconds: 0.5).write(to: url)
        let info = await AudioFileProbe.probe(url)
        XCTAssertTrue(info.exists); XCTAssertTrue(info.hasAudio); XCTAssertTrue(info.isUsable)
        XCTAssertNil(info.problem)
        XCTAssertEqual(info.duration ?? 0, 0.5, accuracy: 0.05)
    }

    func testProbeMissingFile() async {
        let info = await AudioFileProbe.probe(dir.appendingPathComponent("nope.wav"))
        XCTAssertFalse(info.exists); XCTAssertFalse(info.isUsable)
        XCTAssertEqual(info.problem, "File not found")
    }

    func testProbeTextFileNamedWav() async throws {
        let url = dir.appendingPathComponent("fake.wav")
        try Data("this is not audio".utf8).write(to: url)
        let info = await AudioFileProbe.probe(url)
        XCTAssertTrue(info.exists); XCTAssertFalse(info.hasAudio)
        XCTAssertEqual(info.problem, "No audio track in this file")
    }

    func testProbeDirectoryIsNotAFile() async {
        let info = await AudioFileProbe.probe(dir)
        XCTAssertFalse(info.exists)
    }

    func testClampOffset() {
        XCTAssertEqual(AudioFileLogic.clampOffset(-2, fileDuration: 10), 0)
        XCTAssertEqual(AudioFileLogic.clampOffset(4, fileDuration: 10), 4)
        XCTAssertEqual(AudioFileLogic.clampOffset(30, fileDuration: 10), 10)
        XCTAssertEqual(AudioFileLogic.clampOffset(30, fileDuration: nil), 30)
        XCTAssertEqual(AudioFileLogic.clampOffset(.nan, fileDuration: 10), 0)
    }

    func testFormatAndPercent() {
        XCTAssertEqual(AudioFileLogic.formatDuration(12.34), "12.3 s")
        XCTAssertEqual(AudioFileLogic.formatDuration(65.3), "1:05.3")
        XCTAssertEqual(AudioFileLogic.formatDuration(-1), "?")
        XCTAssertEqual(AudioFileLogic.percent(fromVolume: 0.756), 76)
        XCTAssertEqual(AudioFileLogic.percent(fromVolume: 3), 100)
        XCTAssertEqual(AudioFileLogic.volume(fromPercent: 50), 0.5)
        XCTAssertEqual(AudioFileLogic.volume(fromPercent: 150), 1)
        XCTAssertEqual(AudioFileLogic.volume(fromPercent: -5), 0)
    }
}
