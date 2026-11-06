import XCTest
@testable import CC360Framer

final class RecordingTests: XCTestCase {
    typealias V = RecordingSession.View
    private func key(_ t: Double, yaw: Float = 0) -> Keyframe { Keyframe(time: t, yaw: yaw, pitch: 0, fov: 70) }
    private func v(_ yaw: Float, fov: Float = 70) -> V { V(yaw: yaw, pitch: 0.1, fov: fov) }

    func testAnchorHoldsPreMoveView() {
        let s = RecordingSession(time: 5, view: v(0.3))
        XCTAssertEqual(s.recorded.count, 1)
        XCTAssertEqual(s.recorded[0].time, 5)
        XCTAssertEqual(s.recorded[0].yaw, 0.3, accuracy: 1e-6)
    }

    func testThrottle() {
        var s = RecordingSession(time: 5, view: v(0))
        XCTAssertFalse(s.sample(time: 5.2, view: v(1)))
        XCTAssertTrue(s.sample(time: 5.25, view: v(1)))
        XCTAssertFalse(s.sample(time: 5.4, view: v(2)))
        XCTAssertTrue(s.sample(time: 5.5, view: v(2)))
        XCTAssertEqual(s.recorded.map(\.time), [5, 5.25, 5.5])
    }

    func testEndAddsFinalKeyAndOverwritesRange() {
        var s = RecordingSession(time: 10, view: v(0))
        s.sample(time: 10.3, view: v(1))
        let existing = [key(2), key(9.5), key(10.1), key(10.6), key(11.2), key(20)]
        let out = s.end(time: 10.7, view: v(2), keys: existing)
        XCTAssertEqual(out.map(\.time), [2, 9.5, 10, 10.3, 10.7, 11.2, 20])
        XCTAssertEqual(out.first { $0.time == 10.7 }?.yaw ?? 0, 2, accuracy: 1e-6)
    }

    func testOutsideKeysUntouched() {
        var s = RecordingSession(time: 10, view: v(0))
        let existing = [key(1, yaw: 0.5), key(30, yaw: -0.5)]
        let out = s.end(time: 10.5, view: v(1), keys: existing)
        XCTAssertEqual(out.filter { $0.time < 5 || $0.time > 20 }, existing)
    }

    func testBackwardJump() {
        var s = RecordingSession(time: 10, view: v(0))
        XCTAssertTrue(s.sample(time: 10.3, view: v(1)))
        XCTAssertTrue(s.sample(time: 4, view: v(2)))
        let existing = [key(3), key(5), key(7), key(12)]
        let out = s.end(time: 4.5, view: v(3), keys: existing)
        // covered range 4...10.3: keys 5 and 7 are gone, 3 and 12 stay
        XCTAssertEqual(out.map(\.time), [3, 4, 4.5, 10, 10.3, 12])
    }

    func testNearbyExistingKeyIsReplaced() {
        var s = RecordingSession(time: 10, view: v(0))
        let out = s.end(time: 10.0, view: v(1), keys: [key(10.1), key(9.9)])
        XCTAssertEqual(out.count, 1)
    }

    func testSingleBeginEndSameTimeYieldsOneKey() {
        var s = RecordingSession(time: 3, view: v(0.2))
        let out = s.end(time: 3, view: v(0.4), keys: [])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].yaw, 0.4, accuracy: 1e-6)
    }

    func testResultSortedAndUnique() {
        var s = RecordingSession(time: 1, view: v(0))
        for i in 1...20 { s.sample(time: 1 + Double(i) * 0.26, view: v(Float(i) * 0.1)) }
        let out = s.end(time: 6.3, view: v(3), keys: [key(0.5), key(8)])
        XCTAssertEqual(out.map(\.time), out.map(\.time).sorted())
        for (a, b) in zip(out, out.dropFirst()) { XCTAssertGreaterThanOrEqual(b.time - a.time, KeyframeEdit.minSpacing) }
        XCTAssertEqual(Set(out.map(\.id)).count, out.count)
    }

    func testYawWrappingAndClamps() {
        let s = RecordingSession(time: 0, view: V(yaw: 7, pitch: 3, fov: 500))
        XCTAssertLessThanOrEqual(abs(s.recorded[0].yaw), .pi)
        XCTAssertEqual(s.recorded[0].yaw, wrapAngle(7), accuracy: 1e-5)
        XCTAssertEqual(Double(s.recorded[0].pitch), 85 * .pi / 180, accuracy: 1e-5)
        XCTAssertEqual(s.recorded[0].fov, 140)
    }

    func testFreshIdsAndFirstKeysWithoutExisting() {
        var s = RecordingSession(time: 0, view: v(0))
        let out = s.end(time: 0.5, view: v(1), keys: [])
        XCTAssertEqual(out.count, 2)
    }

    @MainActor func testModelRecordingFlagStartsOffAndNeedsFile() {
        let m = PlayerModel()
        XCTAssertFalse(m.isRecording)
        m.toggleRecording()   // no file open: ignored
        XCTAssertFalse(m.isRecording)
    }
}
