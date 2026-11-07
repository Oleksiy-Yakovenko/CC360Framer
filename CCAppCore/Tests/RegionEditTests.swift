import XCTest
@testable import CCAppCore

final class RegionEditTests: XCTestCase {
    private func cut(_ a: Double, _ b: Double) -> CutRegion { CutRegion(start: a, end: b) }
    private func add(_ r: [CutRegion], at t: Double, len: Double = 3, dur: Double = 20) -> (regions: [CutRegion], added: CutRegion)? {
        RegionEdit.add(r, at: t, length: len, duration: dur) { CutRegion(start: $0, end: $1) }
    }

    private func mv(_ r: [CutRegion], _ i: Int, to s: Double, dur: Double = 20, overlap: Bool = false) -> [CutRegion] {
        RegionEdit.move(r, id: r[i].id, toStart: s, duration: dur, allowOverlap: overlap)
    }

    func testMoveKeepsLength() {
        let r = mv([cut(2, 5)], 0, to: 10)
        XCTAssertEqual(r[0].start, 10); XCTAssertEqual(r[0].end, 13)
    }

    func testMoveClampsToClip() {
        XCTAssertEqual(mv([cut(2, 5)], 0, to: -4)[0].start, 0)
        XCTAssertEqual(mv([cut(2, 5)], 0, to: -4)[0].end, 3)
        let e = mv([cut(2, 5)], 0, to: 99)
        XCTAssertEqual(e[0].end, 20); XCTAssertEqual(e[0].start, 17)
    }

    func testMoveStopsAtNeighbours() {
        let regions = [cut(1, 3), cut(6, 8), cut(14, 16)]
        let right = mv(regions, 1, to: 13)
        XCTAssertEqual(right[1].end, 14); XCTAssertEqual(right[1].start, 12)
        let left = mv(regions, 1, to: 0)
        XCTAssertEqual(left[1].start, 3); XCTAssertEqual(left[1].end, 5)
        XCTAssertEqual(right[0], regions[0]); XCTAssertEqual(right[2], regions[2])
    }

    func testMoveDoesNotJumpOver() {
        let r = mv([cut(0, 2), cut(5, 7), cut(10, 12)], 0, to: 18)
        XCTAssertEqual(r[0].end, 5)
    }

    func testMoveTinyRegionAndOverlapAllowed() {
        let tiny = mv([cut(1, 1.2)], 0, to: 5)
        XCTAssertEqual(tiny[0].start, 5, accuracy: 1e-9); XCTAssertEqual(tiny[0].end, 5.2, accuracy: 1e-9)
        let o = mv([cut(1, 3), cut(6, 8)], 1, to: 2, overlap: true)
        XCTAssertEqual(o[1].start, 2)
        let one = [cut(1, 3)]
        XCTAssertEqual(mv(one, 0, to: .nan), one)
    }

    func testAddAtPlayhead() {
        let r = add([], at: 5)!
        XCTAssertEqual(r.added.start, 5); XCTAssertEqual(r.added.end, 8)
        XCTAssertEqual(r.regions.count, 1)
    }

    func testAddNearEndKeepsLength() {
        let r = add([], at: 19)!
        XCTAssertEqual(r.added.start, 17); XCTAssertEqual(r.added.end, 20)
    }

    func testAddStopsAtNextRegion() {
        let r = add([cut(6, 9)], at: 5)!
        XCTAssertEqual(r.added.end, 6)
        XCTAssertEqual(r.regions.map(\.start), [5, 6])
    }

    func testAddRejectedInsideRegionOrWithoutRoom() {
        XCTAssertNil(add([cut(4, 9)], at: 5))
        XCTAssertNil(add([cut(5.1, 9)], at: 5))     // 0.1 s of room < minLength
        XCTAssertNil(add([], at: 1, dur: 0.1))
        XCTAssertNil(add([], at: .nan))
    }

    func testAddAllowOverlap() {
        let r = RegionEdit.add([cut(4, 9)], at: 5, length: 3, duration: 20, allowOverlap: true) { CutRegion(start: $0, end: $1) }!
        XCTAssertEqual(r.regions.count, 2)
    }

    func testAddBeforeRegionAtZero() {
        let r = add([cut(2, 4)], at: 0)!
        XCTAssertEqual(r.added.start, 0); XCTAssertEqual(r.added.end, 2)
    }

    func testMoveEdgeClampsToNeighboursAndClip() {
        let a = cut(2, 4), b = cut(8, 10)
        let all = [a, b]
        XCTAssertEqual(RegionEdit.moveEdge(all, id: b.id, edge: .start, to: 1, duration: 20)[1].start, 4)     // stops at a.end
        XCTAssertEqual(RegionEdit.moveEdge(all, id: a.id, edge: .end, to: 15, duration: 20)[0].end, 8)        // stops at b.start
        XCTAssertEqual(RegionEdit.moveEdge(all, id: a.id, edge: .start, to: -3, duration: 20)[0].start, 0)
        XCTAssertEqual(RegionEdit.moveEdge(all, id: b.id, edge: .end, to: 99, duration: 20)[1].end, 20)
        XCTAssertEqual(RegionEdit.moveEdge(all, id: a.id, edge: .end, to: 2.01, duration: 20)[0].end, 2 + RegionEdit.minLength, accuracy: 1e-9)
        XCTAssertEqual(RegionEdit.moveEdge(all, id: a.id, edge: .start, to: 9, duration: 20)[0].start, 4 - RegionEdit.minLength, accuracy: 1e-9)
        XCTAssertEqual(RegionEdit.moveEdge(all, id: UUID(), edge: .start, to: 1, duration: 20), all)
    }

    func testSetRangeValidation() {
        let a = cut(2, 4), b = cut(8, 10)
        let all = [a, b]
        XCTAssertEqual(RegionEdit.setRange(all, id: a.id, start: 1, end: 7, duration: 20)?[0].end, 7)
        XCTAssertNil(RegionEdit.setRange(all, id: a.id, start: 1, end: 9, duration: 20))      // overlaps b
        XCTAssertNil(RegionEdit.setRange(all, id: a.id, start: 3, end: 3.05, duration: 20))   // too short
        XCTAssertNil(RegionEdit.setRange(all, id: a.id, start: -1, end: 3, duration: 20))
        XCTAssertNil(RegionEdit.setRange(all, id: a.id, start: 1, end: 21, duration: 20))
        XCTAssertNil(RegionEdit.setRange(all, id: a.id, start: .infinity, end: 3, duration: 20))
        XCTAssertEqual(RegionEdit.setRange(all, id: a.id, start: 4, end: 8, duration: 20)?[0].end, 8)   // touching is fine
        // Moving past the other region re-sorts
        XCTAssertEqual(RegionEdit.setRange([a], id: a.id, start: 12, end: 14, duration: 20)?[0].start, 12)
    }

    func testLayoutMapping() {
        let l = TimelineLayout(width: 200, duration: 100, center: 50, visible: 20)   // 10 px per second, 40...60 s
        XCTAssertEqual(l.x(50), 100); XCTAssertEqual(l.x(40), 0); XCTAssertEqual(l.x(60), 200)
        XCTAssertEqual(l.time(150), 55, accuracy: 1e-9)
        XCTAssertEqual(l.time(l.x(12.5)), 12.5, accuracy: 1e-9)
        XCTAssertEqual(l.visibleRange, 40...60)
        // Near the start the window reaches before 0 (negative times, not clamped).
        let s = TimelineLayout(width: 200, duration: 100, center: 0, visible: 20)
        XCTAssertEqual(s.x(0), 100); XCTAssertEqual(s.time(0), -10, accuracy: 1e-9)
        // Default window is the whole clip.
        XCTAssertEqual(TimelineLayout(width: 100, duration: 10).visible, 10)
    }

    func testWindowZoomAndTicks() {
        XCTAssertEqual(TimelineWindow.clampVisible(0.01, duration: 100), 0.1)
        XCTAssertEqual(TimelineWindow.clampVisible(0.5, duration: 100), 0.5)
        XCTAssertEqual(TimelineWindow.clampVisible(500, duration: 100), 200)   // zoom out to twice the video: all of it fits at either end
        XCTAssertEqual(TimelineWindow.clampVisible(150, duration: 100), 150)
        XCTAssertEqual(TimelineWindow.clampVisible(5, duration: 0.01), 0.1)
        XCTAssertEqual(TimelineWindow.clampVisible(5, duration: 1), 2)
        XCTAssertEqual(TimelineWindow.initialVisible(duration: 600), 30)
        XCTAssertEqual(TimelineWindow.initialVisible(duration: 12), 12)
        XCTAssertLessThan(TimelineWindow.wheelFactor(deltaY: 1, precise: false), 1)   // zoom in
        XCTAssertGreaterThan(TimelineWindow.wheelFactor(deltaY: -1, precise: false), 1)
        XCTAssertEqual(TimelineWindow.wheelFactor(deltaY: 0, precise: true), 1)
        XCTAssertLessThan(TimelineWindow.magnifyFactor(0.2), 1)
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 20), 1)
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 100), 0.1)      // sub-second decades down to milliseconds
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 1000), 0.01)
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 10000), 0.001, accuracy: 1e-12)
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 1e6), 0.001, accuracy: 1e-12)   // never finer than 1 ms
        XCTAssertEqual(TimelineWindow.fineTickAlpha(pixelsPerSecond: 1e6, step: 0.001), 0)
        XCTAssertEqual(TimelineWindow.fineTickAlpha(pixelsPerSecond: 500, step: 0.1), (5 - 2) / 4.0, accuracy: 1e-9)   // 10 ms ticks 5 px apart
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 6), 1)
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 3), 10)     // decades only: 1, 10, 100, 1000 s
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 0.6), 10)   // 6 px per 10 s
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 0.5), 100)
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 0.1), 100)
        XCTAssertEqual(TimelineWindow.tickStep(pixelsPerSecond: 0.05), 1000)
        // The finer decade: invisible for 1 s steps, full when it just fits, fading while it gets denser, gone at 2 px.
        XCTAssertEqual(TimelineWindow.fineTickAlpha(pixelsPerSecond: 20, step: 1), 0)
        XCTAssertEqual(TimelineWindow.fineTickAlpha(pixelsPerSecond: 3, step: 10), 0.25, accuracy: 1e-9)   // 1 s ticks 3 px apart
        XCTAssertEqual(TimelineWindow.fineTickAlpha(pixelsPerSecond: 6, step: 10), 1)
        XCTAssertEqual(TimelineWindow.fineTickAlpha(pixelsPerSecond: 0.5, step: 100), 0.75, accuracy: 1e-9)   // 10 s ticks 5 px apart
        XCTAssertEqual(TimelineWindow.fineTickAlpha(pixelsPerSecond: 0.1, step: 100), 0)
        XCTAssertEqual(TimelineWindow.ticks(in: 3.2...8.1, step: 2, duration: 100), [4, 6, 8])
        XCTAssertEqual(TimelineWindow.ticks(in: -5...3, step: 1, duration: 100), [0, 1, 2, 3])
        XCTAssertEqual(TimelineWindow.ticks(in: 8...20, step: 5, duration: 10), [10])
        XCTAssertEqual(TimelineWindow.ticks(in: 12...20, step: 5, duration: 10), [])
    }

    func testLargeTicksAndTimestamps() {
        XCTAssertTrue(TimelineWindow.isLargeTick(10, step: 1))
        XCTAssertFalse(TimelineWindow.isLargeTick(7, step: 1))
        XCTAssertTrue(TimelineWindow.isLargeTick(12.3, step: 0.1) == false)
        XCTAssertTrue(TimelineWindow.isLargeTick(12, step: 0.1))          // floating point: 120 * 0.1
        XCTAssertTrue(TimelineWindow.isLargeTick(0.07 + 0.03, step: 0.01))
        XCTAssertTrue(TimelineWindow.isLargeTick(0, step: 0.001))
        XCTAssertEqual(TimelineWindow.largeTickText(120, step: 10), "2:00")
        XCTAssertEqual(TimelineWindow.largeTickText(10, step: 1), "0:10")
        XCTAssertEqual(TimelineWindow.largeTickText(12, step: 0.1), "0:12")         // large ticks every 1 s: whole seconds
        XCTAssertEqual(TimelineWindow.largeTickText(12.5, step: 0.01), "0:12.5")     // every 0.1 s
        XCTAssertEqual(TimelineWindow.largeTickText(12.05, step: 0.001), "0:12.05")  // every 0.01 s
        XCTAssertEqual(TimelineLayout.timeText(59.96, decimals: 1), "1:00.0")
        XCTAssertEqual(TimelineLayout.timeText(3725.25, decimals: 2), "1:02:05.25")
        XCTAssertEqual(TimelineLayout.timeText(5.004, decimals: 3), "0:05.004")
        XCTAssertEqual(TimelineLayout.timeText(5.4, decimals: 0), "0:05")
        XCTAssertEqual(TimelineLayout.timeText(-1, decimals: 2), "0:00.00")
    }

    func testAutoscrollSpeed() {
        let w = 400.0, v = 30.0
        XCTAssertEqual(TimelineWindow.autoscrollSpeed(pointerX: 200, width: w, visible: v), 0)
        XCTAssertEqual(TimelineWindow.autoscrollSpeed(pointerX: 28, width: w, visible: v), 0)
        XCTAssertEqual(TimelineWindow.autoscrollSpeed(pointerX: 0, width: w, visible: v), -12, accuracy: 1e-9)
        XCTAssertEqual(TimelineWindow.autoscrollSpeed(pointerX: 400, width: w, visible: v), 12, accuracy: 1e-9)
        XCTAssertGreaterThan(TimelineWindow.autoscrollSpeed(pointerX: 380, width: w, visible: v), 0)
        XCTAssertLessThan(TimelineWindow.autoscrollSpeed(pointerX: 380, width: w, visible: v), 12)
        XCTAssertEqual(TimelineWindow.autoscrollSpeed(pointerX: -500, width: w, visible: v), -36, accuracy: 1e-9)   // capped
        XCTAssertEqual(TimelineWindow.autoscrollSpeed(pointerX: 0, width: w, visible: 60), -24, accuracy: 1e-9)   // scales with zoom
    }

    func testPlayheadAndLabel() {
        let l = TimelineLayout(width: 216, duration: 10, center: 5, visible: 4)
        XCTAssertEqual(l.playheadX, 108)
        XCTAssertEqual(l.x(5), l.playheadX)
        XCTAssertEqual(l.labelOriginX(centerX: 108, labelWidth: 40), 88)
        XCTAssertEqual(l.labelOriginX(centerX: 8, labelWidth: 40), 0)       // clamped left
        XCTAssertEqual(l.labelOriginX(centerX: 208, labelWidth: 40), 176)   // clamped right
        XCTAssertEqual(l.labelOriginX(centerX: 5, labelWidth: 300), 0)      // wider than the strip
        XCTAssertEqual(TimelineLayout.timeText(710), "11:50")
        XCTAssertEqual(TimelineLayout.timeText(-3), "0:00")
        XCTAssertEqual(TimelineLayout.timeText(3599.9), "59:59")
        XCTAssertEqual(TimelineLayout.timeText(3725), "1:02:05")
    }

    func testHitTesting() {
        let l = TimelineLayout(width: 200, duration: 10)   // 20 px per second
        let r1 = TimelineItem(id: UUID(), start: 2, end: 4), r2 = TimelineItem(id: UUID(), start: 4.1, end: 8)
        let k = TimelineItem(id: UUID(), start: 9, end: nil)
        let items = [r1, r2, k]
        XCTAssertEqual(l.hit(items, selected: nil, at: l.x(3)), .region(r1.id))
        XCTAssertEqual(l.hit(items, selected: nil, at: l.x(2) + 2), .regionStart(r1.id))
        XCTAssertEqual(l.hit(items, selected: nil, at: l.x(8) - 3), .regionEnd(r2.id))
        XCTAssertEqual(l.hit(items, selected: nil, at: l.x(9) + 3), .point(k.id))
        XCTAssertNil(l.hit(items, selected: nil, at: l.x(0.5)))
        // Between adjacent regions the selected one wins.
        XCTAssertEqual(l.hit(items, selected: r1.id, at: l.x(4) + 1), .regionEnd(r1.id))
        XCTAssertEqual(l.hit(items, selected: r2.id, at: l.x(4) + 1), .regionStart(r2.id))
    }

    func testNavigation() {
        let items = [TimelineItem(id: UUID(), start: 5, end: nil), TimelineItem(id: UUID(), start: 1, end: nil), TimelineItem(id: UUID(), start: 9, end: 10)]
        XCTAssertEqual(TimelineNav.neighbor(items, of: 5, forward: true)?.start, 9)
        XCTAssertEqual(TimelineNav.neighbor(items, of: 5, forward: false)?.start, 1)
        XCTAssertNil(TimelineNav.neighbor(items, of: 9, forward: true))
        XCTAssertNil(TimelineNav.neighbor(items, of: 0.5, forward: false))
    }

    func testSidecarBackCompatAndCuts() throws {
        let old = #"{"globalFov":{"enabled":true,"degrees":80}}"#
        let p = try XCTUnwrap(ProjectSidecar.decode(Data(old.utf8)))
        XCTAssertNil(p.cuts); XCTAssertNil(p.previewWithCuts)
        var q = ProjectSidecar()
        q.cuts = [CutRegion(start: 1, end: 2.5)]
        q.previewWithCuts = true
        let back = try XCTUnwrap(ProjectSidecar.decode(try XCTUnwrap(q.encoded())))
        XCTAssertEqual(back, q)
    }
}
