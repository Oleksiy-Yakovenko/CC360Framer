import XCTest
@testable import CCAppCore

final class GlobalFovTests: XCTestCase {
    private let keys = [Keyframe(time: 0, yaw: 0, pitch: 0, fov: 55), Keyframe(time: 10, yaw: 1, pitch: 0.2, fov: 70)]

    func testDisabledKeepsKeyframeFov() {
        let path = CameraPath(keys: keys)
        let cam = path.sample(at: 0, global: GlobalFov(enabled: false, degrees: 100), fallback: (0, 0, 70))
        XCTAssertEqual(cam.fov, 55)
    }

    func testEnabledOverridesEveryFov() {
        let path = CameraPath(keys: keys)
        let g = GlobalFov(enabled: true, degrees: 100)
        for t in [-1.0, 0, 5, 10, 20] { XCTAssertEqual(path.sample(at: t, global: g, fallback: (0, 0, 70)).fov, 100) }
        // yaw/pitch are untouched
        XCTAssertEqual(path.sample(at: 10, global: g, fallback: (0, 0, 70)).pitch, 0.2, accuracy: 1e-5)
    }

    func testFallbackAlsoOverriddenAndClamped() {
        let empty = CameraPath(keys: [])
        XCTAssertEqual(empty.sample(at: 3, global: GlobalFov(enabled: false), fallback: (0.1, 0.2, 63)).fov, 63)
        XCTAssertEqual(empty.sample(at: 3, global: GlobalFov(enabled: true, degrees: 200), fallback: (0.1, 0.2, 63)).fov, 140)
        XCTAssertEqual(empty.sample(at: 3, global: GlobalFov(enabled: true, degrees: 5), fallback: (0.1, 0.2, 63)).fov, 20)
    }

    func testCodableAndSidecarBackCompat() throws {
        let g = GlobalFov(enabled: true, degrees: 90)
        XCTAssertEqual(try JSONDecoder().decode(GlobalFov.self, from: JSONEncoder().encode(g)), g)
        XCTAssertEqual(try JSONDecoder().decode(GlobalFov.self, from: Data("{}".utf8)), GlobalFov())
        XCTAssertNil(ProjectSidecar.decode(Data("{}".utf8))?.globalFov)
        var p = ProjectSidecar(); p.globalFov = g
        XCTAssertEqual(ProjectSidecar.decode(p.encoded()!)?.globalFov, g)
    }

    func testDefaultsPersistence() {
        let d = UserDefaults(suiteName: "GlobalFovTests")!
        d.removePersistentDomain(forName: "GlobalFovTests")
        XCTAssertEqual(GlobalFov.loadDefaults(d), GlobalFov())
        GlobalFov(enabled: true, degrees: 120).saveDefaults(d)
        XCTAssertEqual(GlobalFov.loadDefaults(d), GlobalFov(enabled: true, degrees: 120))
    }
}
