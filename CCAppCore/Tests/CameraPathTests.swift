import XCTest
@testable import CCAppCore

final class CameraPathTests: XCTestCase {
    func testUserLookIgnoresMomentumAndZeroDeltas() {
        XCTAssertFalse(UserLook.dragCounts(deltaX: 0, deltaY: 0))
        XCTAssertTrue(UserLook.dragCounts(deltaX: 0, deltaY: -1))
        XCTAssertFalse(UserLook.scrollCounts(deltaY: 3, inMomentum: true))
        XCTAssertFalse(UserLook.scrollCounts(deltaY: 0, inMomentum: false))
        XCTAssertTrue(UserLook.scrollCounts(deltaY: 3, inMomentum: false))
        XCTAssertFalse(UserLook.magnifyCounts(magnification: 0))
        XCTAssertTrue(UserLook.magnifyCounts(magnification: 0.01))
    }

    func testSamplingAtManualKeysReturnsKeyValues() throws {
        let rows: [(Double, Double, Double, Float)] = [
            (92.0, 0, 0, 70), (102.527, 61.4, -2.1, 70.0), (103.925, 85.0, -3.8, 70.1),
            (104.956, 131.5, -6.8, 85.6), (105.692, 157.9, -3.0, 85.6), (106.428, 168.5, -3.8, 83.1),
            (109.8, 0, 0, 70),
        ]
        let keys = rows.map { Keyframe(time: $0.0, yaw: Float($0.1 * .pi / 180), pitch: Float($0.2 * .pi / 180), fov: $0.3) }
        let path = CameraPath(keys: keys)
        for k in keys {
            let s = try XCTUnwrap(path.sample(at: k.time))
            XCTAssertEqual(wrapAngle(s.yaw - k.yaw), 0, accuracy: 1e-4, "yaw at \(k.time)")
            XCTAssertEqual(s.pitch, k.pitch, accuracy: 1e-4, "pitch at \(k.time)")
            XCTAssertEqual(s.fov, k.fov, accuracy: 1e-3, "fov at \(k.time)")
        }
    }

    func testWrapAngle() {
        XCTAssertEqual(wrapAngle(3 * .pi / 2), -.pi / 2, accuracy: 1e-5)
        XCTAssertEqual(wrapAngle(-3 * .pi / 2), .pi / 2, accuracy: 1e-5)
        XCTAssertEqual(wrapAngle(0.3), 0.3, accuracy: 1e-6)
    }

    func testEmptyPathSamplesNil() {
        XCTAssertNil(CameraPath(keys: []).sample(at: 1))
    }

    func testSamplingInterpolatesAndClamps() throws {
        let path = CameraPath(keys: [
            Keyframe(time: 0, yaw: 0, pitch: 0, fov: 60),
            Keyframe(time: 10, yaw: 1, pitch: 0.5, fov: 80),
        ])
        let start = try XCTUnwrap(path.sample(at: -5))
        XCTAssertEqual(start.yaw, 0, accuracy: 1e-5)
        let end = try XCTUnwrap(path.sample(at: 99))
        XCTAssertEqual(end.yaw, 1, accuracy: 1e-5)
        XCTAssertEqual(end.fov, 80, accuracy: 1e-4)
        let mid = try XCTUnwrap(path.sample(at: 5))
        XCTAssertEqual(mid.yaw, 0.5, accuracy: 1e-4)
        XCTAssertEqual(mid.pitch, 0.25, accuracy: 1e-4)
        XCTAssertEqual(mid.fov, 70, accuracy: 1e-3)
    }

    func testKeysAreSortedAndYawTakesShortWay() throws {
        let path = CameraPath(keys: [
            Keyframe(time: 2, yaw: -3.0, pitch: 0, fov: 70),
            Keyframe(time: 0, yaw: 3.0, pitch: 0, fov: 70),
        ])
        XCTAssertEqual(path.keys.map(\.time), [0, 2])
        let mid = try XCTUnwrap(path.sample(at: 1))
        // Halfway between 3.0 and -3.0 the short way round is ±pi, not 0.
        XCTAssertGreaterThan(abs(mid.yaw), 3.0)
    }

    func testSampleClampsFovAndPitch() throws {
        let path = CameraPath(keys: [Keyframe(time: 0, yaw: 0, pitch: 0, fov: 500)])
        XCTAssertEqual(try XCTUnwrap(path.sample(at: 0)).fov, 500) // single key: returned as-is
        let two = CameraPath(keys: [
            Keyframe(time: 0, yaw: 0, pitch: 0, fov: 500),
            Keyframe(time: 1, yaw: 0, pitch: 3, fov: 500),
        ])
        let s = try XCTUnwrap(two.sample(at: 0.5))
        XCTAssertEqual(s.fov, 140)
        XCTAssertLessThanOrEqual(s.pitch, 1.5)
    }
}

final class PathBuilderTests: XCTestCase {
    func testNoSamplesGivesNoKeyframes() {
        XCTAssertTrue(PathBuilder.build(samples: [], duration: 10).isEmpty)
    }

    func testConstantTargetDecimatesToEndpoints() {
        let samples = stride(from: 0.0, through: 20, by: 1).map { Sample(t: $0, yaw: 0.4, pitch: 0.1, weight: 1, fov: nil) }
        let keys = PathBuilder.build(samples: samples, duration: 20, fov: 70)
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys.first?.time, 0)
        XCTAssertEqual(keys.last!.time, 20, accuracy: 0.21)
        for k in keys {
            XCTAssertEqual(k.yaw, 0.4, accuracy: 1e-3)
            XCTAssertEqual(k.fov, 70, accuracy: 1e-3)
        }
    }

    func testYawSeamIsNotAveragedThroughZero() {
        // Target sits at the ±pi seam, alternating sides.
        let samples = stride(from: 0.0, through: 20, by: 0.2).enumerated().map { i, t in
            Sample(t: t, yaw: i % 2 == 0 ? 3.1 : -3.1, pitch: 0, weight: 1, fov: nil)
        }
        let keys = PathBuilder.build(samples: samples, duration: 20)
        for k in keys { XCTAssertGreaterThan(abs(k.yaw), 3.0) }
    }

    func testSpeedLimitHolds() {
        // Jump of 180° in one step must turn into a ramp no faster than maxYawSpeed.
        var samples: [Sample] = []
        for i in 0...100 {
            let t = Double(i) * 0.2
            samples.append(Sample(t: t, yaw: t < 10 ? 0 : 2, pitch: 0, weight: 1, fov: nil))
        }
        let params = PathBuilder.Params.follow
        let path = CameraPath(keys: PathBuilder.build(samples: samples, duration: 20, params: params))
        var prev = path.sample(at: 0)!.yaw
        for i in 1...200 {
            let y = path.sample(at: Double(i) * 0.1)!.yaw
            XCTAssertLessThanOrEqual(abs(y - prev) / 0.1, params.maxYawSpeed * 1.35)
            prev = y
        }
    }

    func testPerSampleFovIsUsed() {
        let samples = stride(from: 0.0, through: 10, by: 0.2).map { Sample(t: $0, yaw: 0, pitch: 0, weight: 1, fov: 55) }
        let keys = PathBuilder.build(samples: samples, duration: 10, fov: 70)
        XCTAssertEqual(keys.first!.fov, 55, accuracy: 1e-3)
    }
}
