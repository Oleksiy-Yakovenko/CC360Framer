import XCTest
import AVFoundation
@testable import CCAppCore

final class ExportSettingsTests: XCTestCase {
    func testDefaultsMatchOldPresets() {
        let s = ExportSettings()
        XCTAssertEqual(s.codec, .hevc); XCTAssertEqual(s.container, .mp4)
        XCTAssertEqual(s.outputSize.width, 1920); XCTAssertEqual(s.outputSize.height, 1080)
        XCTAssertEqual(s.bitRate, 20_000_000)
        var k = s; k.resolution = .p2160
        XCTAssertEqual(k.outputSize.width, 3840); XCTAssertEqual(k.outputSize.height, 2160)
        XCTAssertEqual(k.bitRate, 50_000_000)
        var v = s; v.aspect = .a9x16
        XCTAssertEqual(v.outputSize.width, 1080); XCTAssertEqual(v.outputSize.height, 1920)
        v.bitrateMbps = 8
        XCTAssertEqual(v.bitRate, 8_000_000)
    }

    func testAspectSizesAreEven() {
        var s = ExportSettings()
        for a in ExportSettings.Aspect.allCases {
            for r in ExportSettings.Resolution.allCases {
                s.aspect = a; s.resolution = r; s.customAspectW = 7; s.customAspectH = 3; s.customWidth = 1001
                let o = s.outputSize
                XCTAssertEqual(o.width % 2, 0); XCTAssertEqual(o.height % 2, 0)
                XCTAssertGreaterThan(o.width, 0); XCTAssertGreaterThan(o.height, 0)
            }
        }
        s.aspect = .a1x1; s.resolution = .p1080
        XCTAssertEqual(s.outputSize.width, 1080); XCTAssertEqual(s.outputSize.height, 1080)
        s.aspect = .a4x5
        XCTAssertEqual(s.outputSize.width, 1080); XCTAssertEqual(s.outputSize.height, 1350)
        s.aspect = .a4x3
        XCTAssertEqual(s.outputSize.width, 1440); XCTAssertEqual(s.outputSize.height, 1080)
        s.aspect = .custom; s.customAspectW = 7; s.customAspectH = 3; s.resolution = .p720
        XCTAssertEqual(s.outputSize.width, 1680); XCTAssertEqual(s.outputSize.height, 720)
    }

    func testCustomWidth() {
        var s = ExportSettings()
        s.resolution = .custom; s.customWidth = 1001; s.aspect = .a16x9
        XCTAssertEqual(s.outputSize.width, 1002); XCTAssertEqual(s.outputSize.height, 564)   // 563.06 -> 564 (even)
        s.customWidth = 100_000
        XCTAssertEqual(s.outputSize.width, 8192)
        s.customWidth = 1; XCTAssertEqual(s.outputSize.width, 16)
    }

    func testCodableRoundTripAndBackCompat() throws {
        var s = ExportSettings()
        s.container = .mov; s.codec = .h264; s.rateControl = .quality; s.quality = 0.4; s.aspect = .a1x1; s.bitrateMbps = 12; s.crossfade = 1
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: JSONEncoder().encode(s)), s)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: Data("{}".utf8)), ExportSettings())
        let partial = try JSONDecoder().decode(ExportSettings.self, from: Data(#"{"codec":"h264","aspect":"bogus","resolution":"4K"}"#.utf8))
        XCTAssertEqual(partial.codec, .h264); XCTAssertEqual(partial.aspect, .a16x9); XCTAssertEqual(partial.resolution, .p2160)
    }

    func testCompressionProperties() {
        var s = ExportSettings()
        XCTAssertNotNil(s.compressionProperties[AVVideoAverageBitRateKey])
        s.rateControl = .quality; s.quality = 2
        XCTAssertEqual(s.compressionProperties[AVVideoQualityKey] as? Double, 1)
        XCTAssertNil(s.compressionProperties[AVVideoAverageBitRateKey])
        XCTAssertEqual(s.container.fileType, .mp4)
    }

    func testDefaultsPersistence() {
        let d = UserDefaults(suiteName: "ExportSettingsTests")!
        d.removePersistentDomain(forName: "ExportSettingsTests")
        XCTAssertEqual(ExportSettings.loadDefaults(d), ExportSettings())
        var s = ExportSettings(); s.codec = .h264; s.container = .mov
        s.saveDefaults(d)
        XCTAssertEqual(ExportSettings.loadDefaults(d), s)
    }

    func testProjectSidecarBackCompat() throws {
        let old = ProjectSidecar.decode(Data(#"{"locationPlacement":"Top Left"}"#.utf8))
        XCTAssertNil(old?.exportSettings)
        var p = ProjectSidecar(); var s = ExportSettings(); s.codec = .h264; p.exportSettings = s
        XCTAssertEqual(ProjectSidecar.decode(p.encoded()!)?.exportSettings, s)
    }
}
