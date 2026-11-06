import XCTest
@testable import CC360Framer

/// The full ACCL and GPS series (not only the first fix), with the packet timing.
final class TelemetrySeriesTests: XCTestCase {
    private func be32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: UInt32(bitPattern: v).bigEndian) { Array($0) } }
    private func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    private func s16(_ v: Int16) -> [UInt8] { be16(Int(UInt16(bitPattern: v))) }

    private func klv(_ key: String, _ type: Character, size: Int, repeats: Int, _ data: [UInt8]) -> [UInt8] {
        var out = Array(key.utf8) + [type.asciiValue!, UInt8(size), UInt8(repeats >> 8), UInt8(repeats & 0xff)] + data
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    private func nested(_ key: String, _ children: [UInt8]) -> [UInt8] { klv(key, "\0", size: 1, repeats: children.count, children) }

    func testACCLScaledAndTimedWithinPacket() {
        let scal = klv("SCAL", "s", size: 2, repeats: 1, s16(100))
        let rows: [[Int16]] = [[981, 0, -50], [0, 200, 100], [-100, 0, 0], [0, 0, 0]]
        let accl = klv("ACCL", "s", size: 6, repeats: 4, rows.flatMap { $0.flatMap(s16) })
        var t = Telemetry(orientation: [], gravity: [])
        Telemetry.parseGPMF(nested("DEVC", nested("STRM", scal + accl)), into: &t, start: 10, span: 2)
        XCTAssertEqual(t.accel.count, 4)
        XCTAssertEqual(t.accel[0].channels.x, 9.81, accuracy: 1e-4)
        XCTAssertEqual(t.accel[0].channels.z, -0.5, accuracy: 1e-4)
        XCTAssertEqual(t.accel[1].channels.y, 2, accuracy: 1e-4)
        XCTAssertEqual(t.accel[0].t, 10.25, accuracy: 1e-9)   // (0 + 0.5) / 4 * 2 + 10
        XCTAssertEqual(t.accel[3].t, 11.75, accuracy: 1e-9)
    }

    func testGPS9SeriesKeepsEveryFixWithQuality() {
        let scales: [Int32] = [10_000_000, 10_000_000, 1000, 1000, 100, 1, 1000, 100, 1]
        let scal = klv("SCAL", "l", size: 4, repeats: 9, scales.flatMap(be32))
        func row(lat: Int32, speed: Int32, dop: Int, fix: Int) -> [UInt8] {
            [lat, 125_683_000, 20_000, speed, speed, 0, 0].flatMap(be32) + be16(dop) + be16(fix)
        }
        let rows = row(lat: 556_761_000, speed: 0, dop: 9999, fix: 0) + row(lat: 556_762_000, speed: 12_500, dop: 150, fix: 3)
        let gps = klv("GPS9", "?", size: 32, repeats: 2, rows)
        var t = Telemetry(orientation: [], gravity: [])
        Telemetry.parseGPMF(nested("DEVC", nested("STRM", scal + gps)), into: &t, start: 3, span: 1)
        XCTAssertEqual(t.gpsSeries.count, 2)
        XCTAssertFalse(t.gpsSeries[0].isUsable)
        XCTAssertEqual(t.gpsSeries[0].dop, 99.99, accuracy: 1e-9)
        XCTAssertTrue(t.gpsSeries[1].isUsable)
        XCTAssertEqual(t.gpsSeries[1].speed2D, 12.5, accuracy: 1e-9)
        XCTAssertEqual(t.gpsSeries[1].latitude, 55.6762, accuracy: 1e-7)
        XCTAssertEqual(t.gpsSeries[1].dop, 1.5, accuracy: 1e-9)
        XCTAssertEqual(t.gpsSeries[1].t, 3.75, accuracy: 1e-9)
        XCTAssertEqual(t.gps?.latitude ?? 0, 55.6762, accuracy: 1e-7)   // the first-fix logic is unchanged
    }

    func testGPS5SeriesUsesPacketFixAndPrecision() {
        let scal = klv("SCAL", "l", size: 4, repeats: 5, [10_000_000, 10_000_000, 1000, 1000, 100].flatMap(be32))
        let gpsf = klv("GPSF", "L", size: 4, repeats: 1, be32(3))
        let gpsp = klv("GPSP", "S", size: 2, repeats: 1, be16(210))
        let gps = klv("GPS5", "l", size: 20, repeats: 2, [Int32(556_761_000), 125_683_000, 1, 8_000, 8_000, 556_762_000, 125_684_000, 1, 9_000, 9_000].flatMap(be32))
        var t = Telemetry(orientation: [], gravity: [])
        Telemetry.parseGPMF(nested("DEVC", nested("STRM", scal + gpsf + gpsp + gps)), into: &t, start: 0, span: 1)
        XCTAssertEqual(t.gpsSeries.map(\.speed2D), [8, 9])
        XCTAssertEqual(t.gpsSeries[0].fix, 3)
        XCTAssertEqual(t.gpsSeries[0].dop, 2.1, accuracy: 1e-9)
        XCTAssertTrue(t.gpsSeries[0].isUsable)
        XCTAssertEqual(t.gpsSeries[1].longitude, 12.5684, accuracy: 1e-7)
    }

    func testUnlockedOrImpreciseIsNotUsable() {
        XCTAssertFalse(Telemetry.GPSSample(t: 0, latitude: 1, longitude: 1, speed2D: 5, fix: 2, dop: 6, ).isUsable)
        XCTAssertFalse(Telemetry.GPSSample(t: 0, latitude: 1, longitude: 1, speed2D: 5, fix: 1, dop: 1).isUsable)
        XCTAssertTrue(Telemetry.GPSSample(t: 0, latitude: 1, longitude: 1, speed2D: 5, fix: 2, dop: 4.9).isUsable)
    }
}
