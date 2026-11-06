import XCTest
@testable import CC360Framer

final class DirectionLockTests: XCTestCase {
    private func estimate(_ yaw: Double) -> TravelDirection.Estimate {
        let w = (0..<6).map { TravelDirection.Window(time: Double($0) * 10, yaw: yaw, coherence: 0.9, samples: 100, accepted: true) }
        return TravelDirection.Estimate(windows: w, lag: 0, globalYaw: yaw, globalCoherence: 1)
    }

    func testLockOnIsConstantForEveryTime() throws {
        let f = try XCTUnwrap(DirectionLock.forwardYaw(lock: true, lockedYaw: 0.611, mode: .cameraFront, estimate: nil, stabilizer: nil))
        for t in [0.0, 12.5, 999] { XCTAssertEqual(f(t), 0.611, accuracy: 1e-6) }
    }

    func testLockBeatsEstimateAndForwardMode() throws {
        let e = estimate(-0.9)
        let f = try XCTUnwrap(DirectionLock.forwardYaw(lock: true, lockedYaw: 0.3, mode: .travelDirection, estimate: e, stabilizer: nil))
        XCTAssertEqual(f(30), 0.3, accuracy: 1e-6)
    }

    func testLockOnWithZeroIsCameraFrontNotNil() throws {
        let f = try XCTUnwrap(DirectionLock.forwardYaw(lock: true, lockedYaw: 0, mode: .travelDirection, estimate: estimate(0.5), stabilizer: nil))
        XCTAssertEqual(f(10), 0)
    }

    func testLockOffKeepsTodaysBehaviour() throws {
        let e = estimate(0.5)
        XCTAssertNil(DirectionLock.forwardYaw(lock: false, lockedYaw: 1, mode: .cameraFront, estimate: e, stabilizer: nil))
        XCTAssertNil(DirectionLock.forwardYaw(lock: false, lockedYaw: 1, mode: .travelDirection, estimate: nil, stabilizer: nil))
        let f = try XCTUnwrap(DirectionLock.forwardYaw(lock: false, lockedYaw: 1, mode: .travelDirection, estimate: e, stabilizer: nil))
        XCTAssertEqual(f(30), 0.5, accuracy: 0.07)
    }

    func testSceneryForwardShotsSitAtLockedYaw() throws {
        let f = DirectionLock.forwardYaw(lock: true, lockedYaw: 0.611, mode: .cameraFront, estimate: nil, stabilizer: nil)
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
        XCTAssertEqual(old.forwardMode, .cameraFront)
        XCTAssertNil(ProjectSidecar.decode(Data("{}".utf8))?.directionLock)
    }
}
