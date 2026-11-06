import XCTest
@testable import CC360Framer

final class RegionEditTests: XCTestCase {
    private func cut(_ a: Double, _ b: Double) -> CutRegion { CutRegion(start: a, end: b) }
    private func add(_ r: [CutRegion], at t: Double, len: Double = 3, dur: Double = 20) -> (regions: [CutRegion], added: CutRegion)? {
        RegionEdit.add(r, at: t, length: len, duration: dur) { CutRegion(start: $0, end: $1) }
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
        let l = TimelineLayout(width: 216, duration: 10)
        XCTAssertEqual(l.x(0), 8); XCTAssertEqual(l.x(10), 208)
        XCTAssertEqual(l.time(108), 5, accuracy: 1e-9)
        XCTAssertEqual(l.time(-50), 0); XCTAssertEqual(l.time(999), 10)
    }

    func testHitTesting() {
        let l = TimelineLayout(width: 216, duration: 10)   // 20 px per second
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
