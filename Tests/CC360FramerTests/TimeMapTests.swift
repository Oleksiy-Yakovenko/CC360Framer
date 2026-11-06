import XCTest
@testable import CC360Framer

final class TimeMapTests: XCTestCase {
    private func cut(_ a: Double, _ b: Double) -> CutRegion { CutRegion(start: a, end: b) }

    func testNoCuts() {
        let m = TimeMap(cuts: [], duration: 10)
        XCTAssertEqual(m.segments.count, 1)
        XCTAssertFalse(m.hasCuts)
        XCTAssertEqual(m.outputDuration, 10)
        XCTAssertEqual(m.sample(atOutput: 4), TimeMap.Sample(from: 4, to: nil, mix: 0))
    }

    func testMiddleCutHard() {
        let m = TimeMap(cuts: [cut(3, 5)], duration: 10)
        XCTAssertTrue(m.hasCuts)
        XCTAssertEqual(m.segments.map { [$0.sourceStart, $0.sourceEnd, $0.outputStart] }, [[0, 3, 0], [5, 10, 3]])
        XCTAssertEqual(m.outputDuration, 8, accuracy: 1e-9)
        XCTAssertEqual(m.sourceTime(atOutput: 2.5), 2.5)
        XCTAssertEqual(m.sourceTime(atOutput: 3), 5)
        XCTAssertEqual(m.sourceTime(atOutput: 7)!, 9, accuracy: 1e-9)
        XCTAssertEqual(m.outputTime(atSource: 9)!, 7, accuracy: 1e-9)
        XCTAssertNil(m.outputTime(atSource: 4))
        XCTAssertEqual(m.outputTime(atSource: 1), 1)
    }

    func testCutAtStartAndEnd() {
        let m = TimeMap(cuts: [cut(0, 2), cut(8, 10)], duration: 10, crossfade: 1)
        XCTAssertEqual(m.segments.count, 1)
        XCTAssertEqual(m.segments[0].sourceStart, 2)
        XCTAssertEqual(m.outputDuration, 6, accuracy: 1e-9)   // no neighbour, no dissolve
        XCTAssertEqual(m.sourceTime(atOutput: 0), 2)
        XCTAssertEqual(m.sourceTime(atOutput: 6)!, 8, accuracy: 1e-9)
        XCTAssertEqual(m.skipTarget(forSource: 1), 2)
        XCTAssertEqual(m.skipTarget(forSource: 9), 10)
    }

    func testOverlappingAndAdjacentCutsMerge() {
        let m = TimeMap(cuts: [cut(5, 7), cut(2, 4), cut(4, 5), cut(6.5, 8)], duration: 10)
        XCTAssertEqual(m.segments.map { [$0.sourceStart, $0.sourceEnd] }, [[0, 2], [8, 10]])
        XCTAssertEqual(m.outputDuration, 4, accuracy: 1e-9)
    }

    func testCutsClampedAndEmptyDropped() {
        let m = TimeMap(cuts: [cut(-5, 1), cut(9, 20), cut(4, 4), cut(6, 5)], duration: 10)
        XCTAssertEqual(m.segments.map { [$0.sourceStart, $0.sourceEnd] }, [[1, 9]])
    }

    func testAllCut() {
        let m = TimeMap(cuts: [cut(0, 10)], duration: 10, crossfade: 0.5)
        XCTAssertTrue(m.segments.isEmpty)
        XCTAssertEqual(m.outputDuration, 0)
        XCTAssertNil(m.sample(atOutput: 0))
        XCTAssertNil(m.sourceTime(atOutput: 1))
        XCTAssertNil(m.outputTime(atSource: 5))
        XCTAssertEqual(m.skipTarget(forSource: 5), 10)
        XCTAssertTrue(m.hasCuts)
    }

    func testCrossfadeOverlap() {
        let m = TimeMap(cuts: [cut(4, 6)], duration: 10, crossfade: 1)
        // kept 4 + 4, overlap 1: output 7
        XCTAssertEqual(m.outputDuration, 7, accuracy: 1e-9)
        XCTAssertEqual(m.fades, [1])
        XCTAssertEqual(m.segments[1].outputStart, 3, accuracy: 1e-9)
        // before the overlap: plain
        XCTAssertEqual(m.sample(atOutput: 2.9)!.to, nil)
        // overlap start: outgoing at source 3, incoming at source 6, no mix yet
        let a = m.sample(atOutput: 3)!
        XCTAssertEqual(a.from, 3, accuracy: 1e-9); XCTAssertEqual(a.to!, 6, accuracy: 1e-9); XCTAssertEqual(a.mix, 0, accuracy: 1e-9)
        let b = m.sample(atOutput: 3.5)!
        XCTAssertEqual(b.from, 3.5, accuracy: 1e-9); XCTAssertEqual(b.to!, 6.5, accuracy: 1e-9); XCTAssertEqual(b.mix, 0.5, accuracy: 1e-9)
        // after: only the incoming segment
        let c = m.sample(atOutput: 4.2)!
        XCTAssertNil(c.to); XCTAssertEqual(c.from, 7.2, accuracy: 1e-9)
        XCTAssertEqual(m.sourceTime(atOutput: 3.4)!, 3.4, accuracy: 1e-9)
        XCTAssertEqual(m.sourceTime(atOutput: 3.6)!, 6.6, accuracy: 1e-9)
        XCTAssertEqual(m.sample(atOutput: 7)!.from, 10, accuracy: 1e-9)
    }

    func testCrossfadeLimitedByShortSegments() {
        // Segments of 1 s and 5 s: the dissolve may use at most half of the shorter one.
        let m = TimeMap(cuts: [cut(1, 3)], duration: 8, crossfade: 2)
        XCTAssertEqual(m.fades, [0.5])
        XCTAssertEqual(m.outputDuration, 5.5, accuracy: 1e-9)
        for s in m.segments { XCTAssertGreaterThanOrEqual(s.outputStart, 0) }
    }

    func testMultipleCutsContiguousAndMonotonic() {
        let m = TimeMap(cuts: [cut(2, 3), cut(5, 6), cut(8, 9)], duration: 12, crossfade: 0.5)
        XCTAssertEqual(m.segments.count, 4)
        XCTAssertEqual(m.outputDuration, 9 - 1.5, accuracy: 1e-9)
        var prev = -1.0
        var t = 0.0
        while t <= m.outputDuration {
            let s = m.sourceTime(atOutput: t)!
            XCTAssertGreaterThanOrEqual(s, prev - 1e-9)   // never goes backwards, except none at all
            prev = s
            t += 0.05
        }
    }

    func testOutputClamping() {
        let m = TimeMap(cuts: [cut(3, 5)], duration: 10)
        XCTAssertEqual(m.sourceTime(atOutput: -1), 0)
        XCTAssertEqual(m.sourceTime(atOutput: 100)!, 10, accuracy: 1e-9)
    }

    func testJumpPoints() {
        let m = TimeMap(cuts: [cut(3, 5), cut(8, 10)], duration: 10)
        XCTAssertEqual(m.jumpPoints.map { [$0.from, $0.to] }, [[3, 5], [8, 10]])
        XCTAssertEqual(m.skipTarget(forSource: 4), 5)
        XCTAssertEqual(m.skipTarget(forSource: 6), 6)
    }

    func testZeroDuration() {
        let m = TimeMap(cuts: [], duration: 0)
        XCTAssertTrue(m.segments.isEmpty)
        XCTAssertEqual(m.outputDuration, 0)
    }
}
