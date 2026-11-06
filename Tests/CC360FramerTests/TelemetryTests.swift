import XCTest
@testable import CC360Framer

final class TelemetryTests: XCTestCase {
    private func be32(_ v: Int32) -> [UInt8] { withUnsafeBytes(of: UInt32(bitPattern: v).bigEndian) { Array($0) } }

    private func klv(_ key: String, _ type: Character, size: Int, repeats: Int, _ data: [UInt8]) -> [UInt8] {
        var out = Array(key.utf8) + [type.asciiValue!, UInt8(size), UInt8(repeats >> 8), UInt8(repeats & 0xff)] + data
        while out.count % 4 != 0 { out.append(0) }
        return out
    }

    private func nested(_ key: String, _ children: [UInt8]) -> [UInt8] {
        klv(key, "\0", size: 1, repeats: children.count, children)
    }

    private func gps5Blob(lat: Int32, lon: Int32, alt: Int32, scales: [Int32], fix: Int32 = 3) -> [UInt8] {
        let scal = klv("SCAL", "l", size: 4, repeats: scales.count, scales.flatMap(be32))
        let gpsf = klv("GPSF", "L", size: 4, repeats: 1, be32(fix))
        let gps = klv("GPS5", "l", size: 20, repeats: 1, [lat, lon, alt, 0, 0].flatMap(be32))
        return nested("DEVC", nested("STRM", scal + gpsf + gps))
    }

    func testGPS5Altitude() {
        var t = Telemetry(orientation: [], gravity: [])
        // 55.6761 N, 12.5683 E, 23.5 m (scale 1000)
        Telemetry.parseGPMF(gps5Blob(lat: 556_761_000, lon: 125_683_000, alt: 23_500, scales: [10_000_000, 10_000_000, 1000, 1000, 100]), into: &t)
        // lat/lon scaled by 1e7: 55.6761 -> 556_761_000
        XCTAssertEqual(t.gps?.latitude ?? 0, 55.6761, accuracy: 1e-6)
        XCTAssertEqual(t.gps?.longitude ?? 0, 12.5683, accuracy: 1e-6)
        XCTAssertEqual(t.gps?.altitude ?? 0, 23.5, accuracy: 1e-9)
    }

    func testGPS9Altitude() {
        let scales: [Int32] = [10_000_000, 10_000_000, 1000, 1000, 100, 1, 1000, 100, 1]
        let scal = klv("SCAL", "l", size: 4, repeats: 9, scales.flatMap(be32))
        var sample = [Int32(556_761_000), 125_683_000, -4_200, 0, 0, 0, 0, 0].flatMap(be32)
        sample += [0, 3, 0, 0]   // fix=3 at bytes 30...31 of the 36-byte sample
        sample = Array(sample.prefix(32)) + [0, 0, 0, 0]
        sample[30] = 0; sample[31] = 3
        let gps = klv("GPS9", "?", size: 36, repeats: 1, sample)
        var t = Telemetry(orientation: [], gravity: [])
        Telemetry.parseGPMF(nested("DEVC", nested("STRM", scal + gps)), into: &t)
        XCTAssertEqual(t.gps?.altitude ?? 0, -4.2, accuracy: 1e-9)
    }

    func testSettleAltitudeUsesMedian() {
        var t = Telemetry(orientation: [], gravity: [])
        t.gps = Telemetry.GPSFix(latitude: 1, longitude: 1, altitude: -17)
        t.altitudes = [-17, 15, 18, 19, 19]
        t.settleAltitude()
        XCTAssertEqual(t.gps?.altitude, 18)
        t.altitudes = [10, 20]
        t.settleAltitude()
        XCTAssertEqual(t.gps?.altitude, 15)
    }

    func testNoLockNoGPS() {
        var t = Telemetry(orientation: [], gravity: [])
        Telemetry.parseGPMF(gps5Blob(lat: 1, lon: 1, alt: 5, scales: [10_000_000, 10_000_000, 1000], fix: 0), into: &t)
        XCTAssertNil(t.gps)
    }

    func testMissingAltitudeScaleGivesNil() {
        var t = Telemetry(orientation: [], gravity: [])
        Telemetry.parseGPMF(gps5Blob(lat: 556_761_000, lon: 125_683_000, alt: 99, scales: [10_000_000, 10_000_000]), into: &t)
        XCTAssertNotNil(t.gps)
        XCTAssertNil(t.gps?.altitude)
    }

    func testOldPlaceCacheDecodesAndRefreshes() throws {
        let old = #"{"latitude":55.6,"longitude":12.5,"country":"Denmark","place":"Nyhavn"}"#
        let p = try JSONDecoder().decode(PlaceInfo.self, from: Data(old.utf8))
        XCTAssertNil(p.altitude)
        XCTAssertEqual(p.lines.count, 3)
        let q = p.withAltitude(of: Telemetry.GPSFix(latitude: 55.6, longitude: 12.5, altitude: 41.6))
        XCTAssertEqual(q.altitudeText, "42 m")
        XCTAssertEqual(q.lines.last, "42 m")
        XCTAssertNotEqual(p, q)
    }
}
