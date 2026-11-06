import XCTest
@testable import CC360Framer

final class DirectionLockTests: XCTestCase {
    func testLockOnIsConstantForEveryTime() throws {
        let f = try XCTUnwrap(DirectionLock.forwardYaw(lock: true, lockedYaw: 0.611))
        for t in [0.0, 12.5, 999] { XCTAssertEqual(f(t), 0.611, accuracy: 1e-6) }
    }

    func testLockOnWithZeroIsCameraFrontNotNil() throws {
        let f = try XCTUnwrap(DirectionLock.forwardYaw(lock: true, lockedYaw: 0))
        XCTAssertEqual(f(10), 0)
    }

    func testLockOffIsNil() {
        XCTAssertNil(DirectionLock.forwardYaw(lock: false, lockedYaw: 1))
    }

    func testSceneryForwardShotsSitAtLockedYaw() throws {
        let f = DirectionLock.forwardYaw(lock: true, lockedYaw: 0.611)
        let samples = SceneryPlanner.plan([], duration: 30, forwardYaw: f)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { abs($0.yaw - 0.611) < 1e-6 && $0.pitch == 0 })
        let keys = PathStyle.scenery.keyframes(from: [], duration: 30, fov: 70, forwardYaw: f)
        XCTAssertTrue(keys.allSatisfy { abs($0.yaw - 0.611) < 0.01 })
    }

    func testSettledYawRecordsOnlyChanges() {
        XCTAssertNil(DirectionLock.settledYaw(viewYaw: 0.5, stored: 0.5))
        XCTAssertNil(DirectionLock.settledYaw(viewYaw: 0.50005, stored: 0.5))
        XCTAssertEqual(try XCTUnwrap(DirectionLock.settledYaw(viewYaw: 0.7, stored: 0.5)), 0.7, accuracy: 1e-6)
        // wrapped, and equal across the wrap point
        XCTAssertEqual(try XCTUnwrap(DirectionLock.settledYaw(viewYaw: 2 * .pi + 0.2, stored: 0)), 0.2, accuracy: 1e-5)
        XCTAssertNil(DirectionLock.settledYaw(viewYaw: .pi, stored: -.pi))
    }

    func testSettleDebounce() {
        var s = DirectionLock.Settle()
        XCTAssertFalse(s.takeIfSettled(at: 100))          // no drag yet (scroll/pinch never note a drag)
        s.noteDrag(at: 100)
        XCTAssertFalse(s.takeIfSettled(at: 100.2))        // still within the delay
        s.noteDrag(at: 100.3)                             // another drag pushes it out
        XCTAssertFalse(s.takeIfSettled(at: 100.6))
        XCTAssertTrue(s.takeIfSettled(at: 100.71))
        XCTAssertFalse(s.takeIfSettled(at: 101))          // consumed
    }

    func testSummaryText() {
        XCTAssertEqual(DirectionLock.summary(yaw: 0), "Direction lock: forward is the camera front.")
        XCTAssertEqual(DirectionLock.summary(yaw: 0.611), "Direction lock: forward is 35 deg right of the camera front.")
        XCTAssertEqual(DirectionLock.summary(yaw: -0.611), "Direction lock: forward is 35 deg left of the camera front.")
    }

    func testViewStateResetUsesForwardYaw() {
        let v = ViewState()
        v.yaw = 1; v.pitch = 0.3; v.fovDegrees = 100
        v.reset()
        XCTAssertEqual(v.yaw, 0); XCTAssertEqual(v.pitch, 0); XCTAssertEqual(v.fovDegrees, 70)
        v.forwardYaw = 0.611
        v.yaw = -1
        v.reset()
        XCTAssertEqual(v.yaw, 0.611, accuracy: 1e-6)
    }

    func testProjectSidecarRoundTripAndOldFiles() throws {
        var p = ProjectSidecar(); p.directionLock = true; p.lockedYaw = 0.611
        let back = try XCTUnwrap(ProjectSidecar.decode(p.encoded()!))
        XCTAssertEqual(back.directionLock, true)
        XCTAssertEqual(try XCTUnwrap(back.lockedYaw), 0.611, accuracy: 1e-6)
        let old = try XCTUnwrap(ProjectSidecar.decode(Data(#"{"forwardMode":"cameraFront"}"#.utf8)))
        XCTAssertNil(old.directionLock); XCTAssertNil(old.lockedYaw)
        XCTAssertNil(ProjectSidecar.decode(Data("{}".utf8))?.directionLock)
    }
}

final class SceneryRelativeSideTests: XCTestCase {
    private func cand(_ yaw: Float, _ score: Float = 0.9) -> Candidate { Candidate(yaw: yaw, pitch: 0.1, score: score) }
    private func obs(salient: [Float], seconds: Int = 120) -> [Observation] {
        (0..<(seconds * 5)).map { Observation(t: Double($0) * 0.2, people: [cand(.pi, 1)], salient: salient.map { cand($0) }) }
    }
    private func glances(_ s: [Sample], near yaw: Float) -> Bool { s.contains { $0.fov == 55 && abs($0.yaw - yaw) < 1e-3 } }
    private let fwd: Float = 35 * .pi / 180

    func testRightObjectRelativeToForwardIsGlancedAt() {
        let y: Float = 125 * .pi / 180
        let s = SceneryPlanner.plan(obs(salient: [y]), duration: 120, forwardYaw: { _ in self.fwd })
        XCTAssertTrue(glances(s, near: y))
    }

    func testObjectStraightAheadOfForwardIsNoSideGlance() {
        let s = SceneryPlanner.plan(obs(salient: [fwd]), duration: 120, forwardYaw: { _ in self.fwd })
        XCTAssertFalse(s.contains { $0.fov == 55 && abs($0.yaw - self.fwd) < 1e-3 })
        // while it would be ... not a side glance with nil forward either (|yaw| 35 deg is on the edge), use a clear case:
        let y: Float = 60 * .pi / 180   // absolute right side, but only 25 deg off forward
        let s2 = SceneryPlanner.plan(obs(salient: [y]), duration: 120, forwardYaw: { _ in self.fwd })
        XCTAssertFalse(glances(s2, near: y))
        XCTAssertTrue(glances(SceneryPlanner.plan(obs(salient: [y]), duration: 120), near: y))
    }

    func testObjectNearCameraFrontIsLeftSideWhenForwardIsRight() {
        let y: Float = -5 * .pi / 180   // d = -40 deg
        let s = SceneryPlanner.plan(obs(salient: [y]), duration: 120, forwardYaw: { _ in self.fwd })
        XCTAssertTrue(glances(s, near: y))
        XCTAssertFalse(glances(SceneryPlanner.plan(obs(salient: [y]), duration: 120), near: y))  // absolute: too close to front
    }

    func testNilForwardEqualsZeroClosure() {
        let o = obs(salient: [1.5, -2.0, 0.3])
        let a = SceneryPlanner.plan(o, duration: 120)
        let b = SceneryPlanner.plan(o, duration: 120, forwardYaw: { _ in 0 })
        XCTAssertEqual(a.map(\.yaw), b.map(\.yaw))
        XCTAssertEqual(a.map(\.fov), b.map(\.fov))
    }

    func testTimeVaryingForward() {
        let y: Float = 125 * .pi / 180
        // Forward is 35 deg for the first minute (object at d = 90: glance), then 125 deg (d = 0: none).
        let s = SceneryPlanner.plan(obs(salient: [y]), duration: 120, forwardYaw: { $0 < 60 ? 35 * .pi / 180 : 125 * .pi / 180 })
        XCTAssertTrue(s.contains { $0.t < 60 && $0.fov == 55 && abs($0.yaw - y) < 1e-3 })
        // A side shot (up to ~4 s) that started before 60 s may still run past it: check from 66 s on. Rider shots (the test
        // observations contain a person behind the camera) also use fov 55, so look for a glance AT the object.
        XCTAssertFalse(s.contains { $0.t >= 66 && $0.fov == 55 && abs($0.yaw - y) < 1e-3 })
    }
}
