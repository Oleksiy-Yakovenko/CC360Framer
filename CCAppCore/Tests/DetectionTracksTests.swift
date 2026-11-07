import XCTest
@testable import CCAppCore

final class DetectionTracksTests: XCTestCase {
    private func c(_ yaw: Float, _ pitch: Float = 0, _ score: Float = 1) -> Candidate {
        Candidate(yaw: yaw, pitch: pitch, score: score)
    }
    /// One observation per 0.2 s over [from, to].
    private func series(_ from: Double, _ to: Double, people: (Double) -> [Candidate] = { _ in [] },
                        salient: (Double) -> [Candidate] = { _ in [] }) -> [Observation] {
        stride(from: from, through: to + 1e-9, by: 0.2).map { Observation(t: $0, people: people($0), salient: salient($0)) }
    }
    private func count(_ o: [Observation], _ kp: KeyPath<Observation, [Candidate]> = \.people) -> Int { o.reduce(0) { $0 + $1[keyPath: kp].count } }

    func testShortBlipRemovedSteadyTrackKept() {
        let o = series(0, 10, people: { t in
            var l = [self.c(0.1)]                       // steady, whole clip
            if t >= 4 && t <= 5 { l.append(self.c(2.0)) } // 1.0 s blip
            return l
        })
        let f = DetectionTracks.filter(o)
        XCTAssertEqual(count(f), o.count)
        XCTAssertTrue(f.allSatisfy { $0.people.count == 1 && $0.people[0].yaw == 0.1 })
        XCTAssertEqual(f.map(\.t), o.map(\.t))
    }

    func testTrackOf2point4SecondsKept() {
        let o = series(0, 10, people: { t in t >= 3 && t <= 5.4 ? [self.c(1)] : [] })
        XCTAssertEqual(count(DetectionTracks.filter(o)), count(o))
    }

    func testMissingFrameInMiddleStaysOneTrack() {
        let o = series(0, 10, people: { t in t >= 3 && t <= 5.0 && abs(t - 4.0) > 0.01 ? [self.c(1)] : [] })
        XCTAssertEqual(count(DetectionTracks.filter(o)), count(o))
    }

    func testLongGapSplitsTrack() {
        // Two 1.2 s pieces separated by 1 s are two short tracks.
        let o = series(0, 10, people: { t in (t >= 2 && t <= 3.2) || (t >= 4.2 && t <= 5.4) ? [self.c(1)] : [] })
        XCTAssertEqual(count(DetectionTracks.filter(o)), 0)
    }

    func testFastObjectWithinGateStaysOneTrack() {
        // 40 deg/s: 8 deg per step.
        let o = series(0, 10, people: { t in t <= 3 ? [self.c(Float(t) * 40 * .pi / 180)] : [] })
        XCTAssertEqual(count(DetectionTracks.filter(o)), count(o))
    }

    func testObjectsFarApartDoNotMerge() {
        // One object leaves while another appears 90 deg away: two 1.5 s tracks, neither survives.
        let o = series(0, 10, people: { t in t <= 1.5 ? [self.c(0)] : (t <= 3.1 ? [self.c(1.5)] : []) })
        XCTAssertEqual(count(DetectionTracks.filter(o)), 0)
    }

    func testPeopleAndSalientAreNotMixed() {
        // Person for 1.2 s, then a salient object at the same spot for 1.2 s: must not chain into 2.4 s.
        let o = series(0, 10, people: { t in t <= 1.2 ? [self.c(0.5)] : [] },
                       salient: { t in t > 1.2 && t <= 2.4 ? [self.c(0.5)] : [] })
        let f = DetectionTracks.filter(o)
        XCTAssertEqual(count(f), 0)
        XCTAssertEqual(count(f, \.salient), 0)
    }

    func testYawWrapAroundAssociates() {
        let o = series(0, 10, people: { t in
            let i = Int((t / 0.2).rounded())
            return t <= 3 ? [self.c(i % 2 == 0 ? .pi - 0.02 : -.pi + 0.02)] : []
        })
        XCTAssertEqual(count(DetectionTracks.filter(o)), count(o))
    }

    func testClipShorterThanMinimumIsNotFiltered() {
        let o = series(0, 1.0, people: { _ in [self.c(0)] })
        XCTAssertEqual(count(DetectionTracks.filter(o)), count(o))
        // Observations covering only 1 s of a longer clip are filtered.
        XCTAssertEqual(count(DetectionTracks.filter(o, clipDuration: 30)), 0)
    }

    func testUnsortedInputIsSorted() {
        let o = series(0, 10, people: { _ in [self.c(0)] }).reversed() as [Observation]
        let f = DetectionTracks.filter(o)
        XCTAssertEqual(f.map(\.t), f.map(\.t).sorted())
        XCTAssertEqual(count(f), count(o))
    }

    func testKeepsCornersAndScore() {
        var cand = c(0, 0, 0.7); cand.corners = [1, 2, 3, 4, 5, 6, 7, 8]
        let o = series(0, 3, people: { _ in [cand] })
        let f = DetectionTracks.filter(o)
        XCTAssertEqual(f[0].people[0].corners, cand.corners)
        XCTAssertEqual(f[0].people[0].score, 0.7)
    }

    func testFollowSamplesTargetPersistentPersonNotBlip() {
        // A bigger person appears for 1 s far from the persistent one; keyframes must stay on the persistent one.
        let o = series(0, 20, people: { t in
            var l = [self.c(0.3, 0, 0.5)]
            if t >= 8 && t <= 9 { l.append(self.c(2.5, 0, 5)) }
            return l
        })
        let keys = PathStyle.follow.keyframes(from: o, duration: 20, fov: 70)
        XCTAssertFalse(keys.isEmpty)
        for k in keys { XCTAssertEqual(k.yaw, 0.3, accuracy: 1e-3) }
    }

    func testFollowWithOnlyBlipsGivesNoKeyframes() {
        let o = series(0, 20, people: { t in t >= 8 && t <= 9 ? [self.c(2.5)] : [] })
        XCTAssertTrue(PathStyle.follow.keyframes(from: o, duration: 20, fov: 70).isEmpty)
    }

    func testSceneryIgnoresShortSalientBlip() {
        // Salient object on the right for 1 s only: every shot is forward (yaw 0, fov 70).
        let o = series(0, 40, salient: { t in t >= 8 && t <= 9 ? [self.c(1.2, 0, 1)] : [] })
        let keys = PathStyle.scenery.keyframes(from: o, duration: 40, fov: 70)
        XCTAssertFalse(keys.isEmpty)
        for k in keys { XCTAssertEqual(k.yaw, 0, accuracy: 1e-3) }
    }

    func testSceneryFollowsPersistentSalient() {
        let o = series(0, 40, salient: { t in t >= 6 && t <= 14 ? [self.c(1.2, 0, 1)] : [] })
        let keys = PathStyle.scenery.keyframes(from: o, duration: 40, fov: 70)
        XCTAssertTrue(keys.contains { abs($0.yaw - 1.2) < 0.05 })
    }
}
