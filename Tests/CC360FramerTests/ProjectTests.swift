import XCTest
@testable import CC360Framer

final class ProjectTests: XCTestCase {
    func testStyleDefaultsReproduceOriginalCard() {
        let s = LocationCardStyle()
        XCTAssertNil(s.fontName)
        XCTAssertEqual(s.sizes(lineCount: 3), [64, 44, 34])
        XCTAssertEqual(s.sizes(lineCount: 4), [64, 44, 34, 34])
        XCTAssertEqual(s.sizes(lineCount: 2), [44, 44])
        XCTAssertEqual(s.fill, CardColor(r: 1, g: 1, b: 1, a: 1))
        XCTAssertEqual(s.strokeWidth, 0)
    }

    func testSizesScaleWithBase() {
        var s = LocationCardStyle(); s.baseSize = 128
        XCTAssertEqual(s.sizes(lineCount: 3), [128, 88, 68])
    }

    func testStyleRoundTripAndPartialDecode() throws {
        let s = LocationCardStyle(fontName: "Menlo", baseSize: 80, fill: CardColor(r: 1, g: 0.5, b: 0, a: 1),
                                  stroke: CardColor(r: 0, g: 0, b: 1, a: 0.5), strokeWidth: 3)
        XCTAssertEqual(try JSONDecoder().decode(LocationCardStyle.self, from: JSONEncoder().encode(s)), s)
        let partial = try JSONDecoder().decode(LocationCardStyle.self, from: Data(#"{"baseSize": 90}"#.utf8))
        XCTAssertEqual(partial, LocationCardStyle(baseSize: 90))
    }

    func testImageRendersForStyles() {
        let info = PlaceInfo(latitude: 55, longitude: 12, country: "Denmark", place: "Nyhavn", altitude: 5)
        let plain = LocationOverlay.image(for: info, placement: .bottomLeft)
        var big = LocationCardStyle(); big.baseSize = 128; big.strokeWidth = 4; big.fontName = "Menlo"
        let styled = LocationOverlay.image(for: info, placement: .bottomLeft, style: big)
        XCTAssertNotNil(plain)
        XCTAssertGreaterThan(styled!.width, plain!.width)
    }

    func testProjectRoundTripAndBackwardCompat() throws {
        let p = ProjectSidecar(locationStyle: LocationCardStyle(baseSize: 70), locationPlacement: .topRight)
        XCTAssertEqual(ProjectSidecar.decode(p.encoded()!), p)
        // Empty, and files with unknown (future) keys, still load.
        XCTAssertEqual(ProjectSidecar.decode(Data("{}".utf8)), ProjectSidecar())
        let future = ProjectSidecar.decode(Data(#"{"locationPlacement":"Centre","cuts":[1,2]}"#.utf8))
        XCTAssertEqual(future?.locationPlacement, .center)
        XCTAssertNil(future?.locationStyle)
    }

    func testProjectSaveLoadViaSidecarFolder() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let v = d.appendingPathComponent("a.360")
        XCTAssertEqual(ProjectSidecar.load(for: v), ProjectSidecar())
        let p = ProjectSidecar(locationStyle: LocationCardStyle(fontName: "Menlo"), locationPlacement: .bottomRight)
        p.save(for: v)
        XCTAssertEqual(ProjectSidecar.load(for: v), p)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Sidecar.url(for: v, kind: "project").path))
    }

    // MARK: Keyframe edit

    private func keys() -> [Keyframe] {
        [Keyframe(time: 1, yaw: 0, pitch: 0, fov: 70), Keyframe(time: 5, yaw: 0.5, pitch: 0.1, fov: 60), Keyframe(time: 9, yaw: 0, pitch: 0, fov: 70)]
    }

    func testEditChangesValuesInDegrees() throws {
        let ks = keys()
        var v = KeyframeEdit.Values(ks[1])
        v.yaw = 90; v.pitch = 10; v.fov = 55
        let out = try XCTUnwrap(KeyframeEdit.apply(ks, id: ks[1].id, v, duration: 20))
        XCTAssertEqual(out[1].yaw, .pi / 2, accuracy: 1e-5)
        XCTAssertEqual(out[1].pitch, 10 * .pi / 180, accuracy: 1e-5)
        XCTAssertEqual(out[1].fov, 55)
    }

    func testEditResortsByTime() throws {
        let ks = keys()
        var v = KeyframeEdit.Values(ks[0]); v.time = 7
        let out = try XCTUnwrap(KeyframeEdit.apply(ks, id: ks[0].id, v, duration: 20))
        XCTAssertEqual(out.map(\.time), [5, 7, 9])
        XCTAssertEqual(out[1].id, ks[0].id)
    }

    func testEditClampsAndWraps() throws {
        let ks = keys()
        let v = KeyframeEdit.Values(time: 99, yaw: 190, pitch: 120, fov: 500)
        let out = try XCTUnwrap(KeyframeEdit.apply(ks, id: ks[2].id, v, duration: 12))
        XCTAssertEqual(out[2].time, 12)
        XCTAssertEqual(out[2].yaw, -170 * .pi / 180, accuracy: 1e-5)
        XCTAssertEqual(Double(out[2].pitch), 85 * .pi / 180, accuracy: 1e-5)
        XCTAssertEqual(out[2].fov, 140)
        XCTAssertEqual(try XCTUnwrap(KeyframeEdit.apply(ks, id: ks[0].id, .init(time: -3, yaw: 0, pitch: 0, fov: 1), duration: 12))[0].fov, 20)
    }

    func testEditRejectsCollisionsUnknownIdAndNaN() {
        let ks = keys()
        var v = KeyframeEdit.Values(ks[0]); v.time = 5.02
        XCTAssertNil(KeyframeEdit.apply(ks, id: ks[0].id, v, duration: 20))
        XCTAssertNil(KeyframeEdit.apply(ks, id: UUID(), KeyframeEdit.Values(ks[0]), duration: 20))
        v = KeyframeEdit.Values(ks[0]); v.yaw = .nan
        XCTAssertNil(KeyframeEdit.apply(ks, id: ks[0].id, v, duration: 20))
    }
}
