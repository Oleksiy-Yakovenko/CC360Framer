import XCTest
@testable import CC360Framer

final class StylesTests: XCTestCase {
    private func cand(_ yaw: Float, _ pitch: Float = 0, _ score: Float = 1) -> Candidate {
        Candidate(yaw: yaw, pitch: pitch, score: score)
    }

    func testContinuityWeightBoostsNearbyCandidates() {
        let prev: (yaw: Float, pitch: Float) = (0, 0)
        let near = continuityWeight(cand(0.05), prev)
        let far = continuityWeight(cand(2.5), prev)
        XCTAssertGreaterThan(near, far)
        XCTAssertEqual(continuityWeight(cand(1, 0, 0.7), nil), 0.7, accuracy: 1e-6)
        XCTAssertEqual(continuityWeight(cand(0), prev), 3, accuracy: 1e-5) // 1 + 2 at zero distance
    }

    func testContinuityWeightWrapsAcrossSeam() {
        let w = continuityWeight(cand(-3.1), (yaw: 3.1, pitch: 0))
        XCTAssertGreaterThan(w, 2) // 0.08 rad apart, not 6.2
    }

    func testFollowSamplesSkipsFramesWithoutPeopleAndSticksToTarget() {
        let obs = [
            Observation(t: 0, people: [cand(0, 0, 1)], salient: []),
            Observation(t: 1, people: [], salient: []),
            // Bigger person far away vs smaller person near the previous target: continuity wins.
            Observation(t: 2, people: [cand(2.0, 0, 1.2), cand(0.1, 0, 0.8)], salient: []),
        ]
        let s = PathStyle.followSamples(obs)
        XCTAssertEqual(s.map(\.t), [0, 2])
        XCTAssertEqual(s[1].yaw, 0.1, accuracy: 1e-6)
    }

    func testFollowKeyframesPointAtSubject() {
        let obs = stride(from: 0.0, through: 30, by: 0.2).map { Observation(t: $0, people: [cand(0.5, 0.1)], salient: []) }
        let keys = PathStyle.follow.keyframes(from: obs, duration: 30, fov: 70)
        XCTAssertFalse(keys.isEmpty)
        for k in keys {
            XCTAssertEqual(k.yaw, 0.5, accuracy: 1e-3)
            XCTAssertEqual(k.fov, 70, accuracy: 1e-3)
        }
    }

    func testSceneryWithoutObservationsLooksForward() {
        let samples = SceneryPlanner.plan([], duration: 30)
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.yaw == 0 && $0.fov == 70 })
        XCTAssertEqual(samples.count, Int(30 / 0.2) + 1)
    }

    func testSceneryGlancesAtSideObjectsAndLimitsRiderShots() {
        var obs: [Observation] = []
        for i in 0..<600 { // 2 min at 0.2 s
            obs.append(Observation(t: Double(i) * 0.2, people: [cand(.pi, 0, 1)],
                                   salient: [cand(1.5, 0.1, 0.9)]))
        }
        let samples = SceneryPlanner.plan(obs, duration: 120)
        XCTAssertTrue(samples.contains { abs($0.yaw - 1.5) < 1e-3 && $0.fov == 55 })
        // The rider (yaw pi) is never chosen while side objects are interesting.
        XCTAssertFalse(samples.contains { abs($0.yaw) > 3 })
    }

    func testSceneryRiderShotsAreRare() {
        // Nothing salient: side slots fall back to rider shots, at most 2 in total.
        let obs = (0..<900).map { Observation(t: Double($0) * 0.2, people: [cand(.pi, 0, 1)], salient: []) }
        let samples = SceneryPlanner.plan(obs, duration: 180)
        var shots = 0, inShot = false
        for s in samples {
            let rider = abs(s.yaw) > 3
            if rider && !inShot { shots += 1 }
            inShot = rider
        }
        XCTAssertGreaterThan(shots, 0)
        XCTAssertLessThanOrEqual(shots, 2)
    }
}
