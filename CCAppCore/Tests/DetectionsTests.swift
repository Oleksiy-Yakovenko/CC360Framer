import XCTest
import simd
@testable import CCAppCore

final class DetectionsTests: XCTestCase {
    private func obs(_ ts: [Double]) -> [Observation] { ts.map { Observation(t: $0, people: [], salient: []) } }
    private func cam(yaw: Float = 0, pitch: Float = 0, fov: Float = 90, aspect: Float = 1, basis: Stabilizer.Basis = .identity) -> Detections.Camera {
        .init(yaw: yaw, pitch: pitch, tanHalfFov: tan(fov * .pi / 360), aspect: aspect, basis: basis)
    }

    func testObservationNearest() {
        let o = obs([0, 0.2, 0.4, 0.6])
        XCTAssertEqual(Detections.observation(in: o, at: 0.27)?.t, 0.2)
        XCTAssertEqual(Detections.observation(in: o, at: 0.33)?.t, 0.4)
        XCTAssertEqual(Detections.observation(in: o, at: 0.0)?.t, 0)
        XCTAssertEqual(Detections.observation(in: o, at: 0.7)?.t, 0.6)
    }

    func testObservationNoneWhenFarOrEmpty() {
        XCTAssertNil(Detections.observation(in: [], at: 1))
        let o = obs([1, 1.2, 5, 5.2])
        XCTAssertNil(Detections.observation(in: o, at: 0.5))
        XCTAssertNil(Detections.observation(in: o, at: 3))
        XCTAssertNil(Detections.observation(in: o, at: 6))
        XCTAssertEqual(Detections.observation(in: o, at: 5.1)?.t, 5.0)
    }

    func testCentreAndEdges() {
        let c = cam()
        let p = Detections.project(yaw: 0, pitch: 0, camera: c)!
        XCTAssertEqual(p.x, 0, accuracy: 1e-5); XCTAssertEqual(p.y, 0, accuracy: 1e-5)
        let r = Detections.project(yaw: .pi / 4, pitch: 0, camera: c)!   // +fov/2 horizontally at aspect 1
        XCTAssertEqual(r.x, 1, accuracy: 1e-4)
        let u = Detections.project(yaw: 0, pitch: .pi / 4, camera: c)!
        XCTAssertEqual(u.y, 1, accuracy: 1e-4)
        let wide = Detections.project(yaw: .pi / 4, pitch: 0, camera: cam(aspect: 2))!
        XCTAssertEqual(wide.x, 0.5, accuracy: 1e-4)
    }

    func testBehindCameraIsNil() {
        XCTAssertNil(Detections.project(yaw: .pi, pitch: 0, camera: cam()))
        XCTAssertNil(Detections.project(yaw: 2, pitch: 0, camera: cam()))
    }

    func testLookingAtDirectionCentresIt() {
        let c = cam(yaw: 0.7, pitch: 0.3)
        let p = Detections.project(yaw: 0.7, pitch: 0.3, camera: c)!
        XCTAssertEqual(p.x, 0, accuracy: 1e-4); XCTAssertEqual(p.y, 0, accuracy: 1e-4)
        // Looking right of a point moves it to the left of the screen.
        XCTAssertLessThan(Detections.project(yaw: 0.6, pitch: 0.3, camera: c)!.x, 0)
        XCTAssertGreaterThan(Detections.project(yaw: 0.7, pitch: 0.4, camera: c)!.y, 0)
    }

    func testRotatedBasis() {
        // Virtual camera turned 90 degrees to the body's right: body +x is the virtual forward.
        let b = Stabilizer.Basis(right: [0, 0, -1], up: [0, 1, 0], forward: [1, 0, 0])
        let p = Detections.project(yaw: .pi / 2, pitch: 0, camera: cam(basis: b))!
        XCTAssertEqual(p.x, 0, accuracy: 1e-5); XCTAssertEqual(p.y, 0, accuracy: 1e-5)
        XCTAssertNil(Detections.project(yaw: 0, pitch: 0, camera: cam(basis: b)))   // body front is now exactly side-on: not in front
    }

    func testAgreesWithShaderMapping() {
        // Forward mapping as in the Metal shader, then project the resulting body direction back.
        let c = cam(yaw: -0.4, pitch: 0.25, fov: 70, aspect: 1.7, basis: Stabilizer.Basis(right: [0, 0, -1], up: [0, 1, 0], forward: [1, 0, 0]))
        for ndc in [SIMD2<Float>(0.3, -0.6), SIMD2(-0.9, 0.8), SIMD2(0, 0)] {
            var d = simd_normalize(SIMD3<Float>(ndc.x * c.aspect * c.tanHalfFov, ndc.y * c.tanHalfFov, 1))
            d = SIMD3(d.x, d.y * cos(c.pitch) + d.z * sin(c.pitch), -d.y * sin(c.pitch) + d.z * cos(c.pitch))
            d = SIMD3(d.x * cos(c.yaw) + d.z * sin(c.yaw), d.y, -d.x * sin(c.yaw) + d.z * cos(c.yaw))
            let body = simd_normalize(c.basis.right * d.x + c.basis.up * d.y + c.basis.forward * d.z)
            let p = Detections.project(yaw: atan2(body.x, body.z), pitch: asin(body.y), camera: c)!
            XCTAssertEqual(p.x, ndc.x, accuracy: 1e-4); XCTAssertEqual(p.y, ndc.y, accuracy: 1e-4)
        }
    }

    func testGuideScalesFov() {
        let plain = Detections.previewTanHalfFov(fovDegrees: 70, previewAspect: 2, exportAspect: nil)
        XCTAssertEqual(plain, tan(Float.pi * 70 / 360), accuracy: 1e-6)
        // Export frame narrower than the view: full height, scale 1. Wider (aspect 4 in a 2 view): scale = 2.
        XCTAssertEqual(Detections.previewTanHalfFov(fovDegrees: 70, previewAspect: 2, exportAspect: 1), plain, accuracy: 1e-6)
        XCTAssertEqual(Detections.previewTanHalfFov(fovDegrees: 70, previewAspect: 2, exportAspect: 4), plain * 2, accuracy: 1e-5)
    }

    func testShapesBoxesPointsAndSkips() {
        let box = Candidate(yaw: 0, pitch: 0, score: 1, corners: [-0.1, -0.1, 0.1, -0.1, 0.1, 0.1, -0.1, 0.1])
        let legacy = Candidate(yaw: 0.2, pitch: 0, score: 1)
        let behind = Candidate(yaw: .pi, pitch: 0, score: 1, corners: [3, 0, 3.1, 0, 3.1, 0.1, 3, 0.1])
        let o = Observation(t: 0, people: [box, behind], salient: [legacy])
        let s = Detections.shapes(for: o, camera: cam())
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].kind, .person); XCTAssertEqual(s[0].points.count, 4)
        XCTAssertLessThan(s[0].points[0].x, 0); XCTAssertLessThan(s[0].points[0].y, 0)
        XCTAssertEqual(s[1].kind, .salient); XCTAssertTrue(s[1].isPoint)
    }

    func testCandidateDecodesWithoutCorners() throws {
        let old = #"{"t":1.5,"people":[{"yaw":0.1,"pitch":0.2,"score":0.5}],"salient":[]}"#
        let o = try JSONDecoder().decode(Observation.self, from: Data(old.utf8))
        XCTAssertNil(o.people[0].corners)
        let c = Candidate(yaw: 0, pitch: 0, score: 1, corners: [1, 2, 3, 4, 5, 6, 7, 8])
        let back = try JSONDecoder().decode(Candidate.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.corners, c.corners)
    }
}

final class DetectionGroupsTests: XCTestCase {
    /// Person box centred at (yaw, 0), `w` wide and `h` tall (radians).
    private func p(_ yaw: Float, w: Float = 0.1, h: Float = 0.3, pitch: Float = 0, score: Float = 0.9) -> Candidate {
        let l = yaw - w / 2, r = yaw + w / 2, b = pitch - h / 2, t = pitch + h / 2
        return Candidate(yaw: yaw, pitch: pitch, score: score, corners: [l, b, r, b, r, t, l, t])
    }
    private func cam() -> Detections.Camera { .init(yaw: 0, pitch: 0, tanHalfFov: 1, aspect: 1) }

    func testDuplicatesFromTwoViewsMerge() {
        let m = DetectionGroups.merged([p(0.50, score: 0.6), p(0.51, w: 0.09, score: 0.8)])
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].score, 0.8)
    }

    func testAdjacentDifferentPeopleDoNotMerge() {
        XCTAssertEqual(DetectionGroups.merged([p(0.0), p(0.12)]).count, 2)
    }

    func testMergeAcrossSeam() {
        let a = p(.pi - 0.01), b = p(-.pi + 0.01)
        XCTAssertEqual(DetectionGroups.merged([a, b]).count, 1)
        XCTAssertEqual(DetectionGroups.merged([a, p(-.pi + 0.3)]).count, 2)
    }

    func testPersonAndSalientNotMerged() {
        let o = Observation(t: 0, people: [p(0)], salient: [p(0)])
        let s = Detections.shapes(for: o, camera: cam())
        XCTAssertEqual(s.filter { $0.kind == .person }.count, 1)
        XCTAssertEqual(s.filter { $0.kind == .salient }.count, 1)
    }

    func testLegacyUntouched() {
        let l = Candidate(yaw: 0, pitch: 0, score: 1)
        XCTAssertEqual(DetectionGroups.merged([l, l, p(0)]).count, 3)
        XCTAssertTrue(DetectionGroups.groups([l, l, l]).isEmpty)
    }

    func testRowOfFiveMakesOneGroupCoveringAll() {
        let people = (0..<5).map { p(Float($0) * 0.13) }
        let g = DetectionGroups.groups(DetectionGroups.merged(people))
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].yaw - g[0].halfW, -0.05, accuracy: 1e-4)
        XCTAssertEqual(g[0].yaw + g[0].halfW, 0.52 + 0.05, accuracy: 1e-4)
        XCTAssertEqual(g[0].halfH, 0.15, accuracy: 1e-4)
        let s = Detections.shapes(for: Observation(t: 0, people: people, salient: []), camera: cam())
        XCTAssertEqual(s.filter { $0.kind == .person }.count, 5)
        XCTAssertEqual(s.filter { $0.kind == .group }.count, 1)
    }

    func testTwoPeopleNoGroup() {
        XCTAssertTrue(DetectionGroups.groups([p(0), p(0.13)]).isEmpty)
    }

    func testTwoFarClustersAndLoner() {
        let a = (0..<3).map { p(Float($0) * 0.13) }
        let b = (0..<4).map { p(1.5 + Float($0) * 0.13) }
        let loner = p(0.9)
        XCTAssertEqual(DetectionGroups.groups(a + b + [loner]).count, 2)
        // The loner is not absorbed into the first group.
        let g = DetectionGroups.groups(a + [loner])
        XCTAssertEqual(g.count, 1)
        XCTAssertLessThan(g[0].yaw + g[0].halfW, 0.5)
    }

    func testGroupAcrossSeam() {
        let g = DetectionGroups.groups([p(.pi - 0.13), p(.pi), p(-.pi + 0.13)])
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].halfW, 0.18, accuracy: 1e-4)
    }

    func testGroupBehindCameraSkipped() {
        let people = (0..<3).map { p(.pi + Float($0) * 0.13) }
        let s = Detections.shapes(for: Observation(t: 0, people: people, salient: []), camera: cam())
        XCTAssertTrue(s.isEmpty)
    }
}
