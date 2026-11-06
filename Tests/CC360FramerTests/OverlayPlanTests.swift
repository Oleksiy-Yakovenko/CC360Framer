import XCTest
@testable import CC360Framer

final class OverlayPlanTests: XCTestCase {
    private func key(_ t: Double, _ p: OverlayPlacement = .topLeft) -> LocationCardKey { LocationCardKey(time: t, placement: p) }

    func testAutoCardWithoutKeys() {
        let a = LocationCards.active(keys: [], autoEnabled: true, autoPlacement: .center, at: 5)
        XCTAssertEqual(a, .init(placement: .center, alpha: 1))
        XCTAssertNil(LocationCards.active(keys: [], autoEnabled: true, autoPlacement: .center, at: 12))
        XCTAssertNil(LocationCards.active(keys: [], autoEnabled: false, autoPlacement: .center, at: 5))
    }

    func testKeysReplaceAutoCard() {
        let keys = [key(30, .topRight)]
        // The automatic card at the start is ignored once keys exist.
        XCTAssertNil(LocationCards.active(keys: keys, autoEnabled: true, autoPlacement: .center, at: 5))
        let a = LocationCards.active(keys: keys, autoEnabled: true, autoPlacement: .center, at: 35)
        XCTAssertEqual(a?.placement, .topRight)
        XCTAssertEqual(a?.alpha, 1)
        XCTAssertNil(LocationCards.active(keys: keys, autoEnabled: true, autoPlacement: .center, at: 40.5))
        XCTAssertEqual(LocationCards.active(keys: keys, autoEnabled: false, autoPlacement: .center, at: 30.3)?.alpha ?? 0, 0.5, accuracy: 1e-5)
    }

    func testNextKeyReplacesCard() {
        let keys = [key(10, .topLeft), key(14, .bottomRight)]
        XCTAssertEqual(LocationCards.active(keys: keys, autoEnabled: true, autoPlacement: .center, at: 12)?.placement, .topLeft)
        XCTAssertEqual(LocationCards.active(keys: keys, autoEnabled: true, autoPlacement: .center, at: 16)?.placement, .bottomRight)
    }

    func testAddAndSet() throws {
        let r = try XCTUnwrap(LocationCards.add([], at: 20, placement: .center, duration: 100))
        XCTAssertEqual(r.keys, [r.added])
        XCTAssertNil(LocationCards.add(r.keys, at: 20.05, placement: .center, duration: 100))
        let r2 = try XCTUnwrap(LocationCards.add(r.keys, at: 5, placement: .topLeft, duration: 100))
        XCTAssertEqual(r2.keys.map(\.time), [5, 20])
        XCTAssertEqual(try XCTUnwrap(LocationCards.add([], at: 500, placement: .center, duration: 100)).added.time, 100)
        let moved = try XCTUnwrap(LocationCards.set(r2.keys, id: r2.added.id, time: 50, placement: .bottomLeft, duration: 100))
        XCTAssertEqual(moved.map(\.time), [20, 50])
        XCTAssertEqual(moved[1].placement, .bottomLeft)
        XCTAssertNil(LocationCards.set(r2.keys, id: r2.added.id, time: 20.1, placement: .center, duration: 100))
        XCTAssertNil(LocationCards.set(r2.keys, id: UUID(), time: 50, placement: .center, duration: 100))
        XCTAssertNil(LocationCards.set(r2.keys, id: r2.added.id, time: .nan, placement: .center, duration: 100))
    }

    func testPlanDrawsAndImageKeys() {
        var plan = OverlayPlan(hasPlace: true, autoCard: true, autoPlacement: .bottomLeft, cardKeys: [])
        XCTAssertEqual(plan.draws(at: 3).map(\.key), ["card.-1"])
        XCTAssertTrue(plan.draws(at: 20).isEmpty)
        plan.cardKeys = [key(20, .topRight), key(60, .center)]
        XCTAssertTrue(plan.draws(at: 3).isEmpty)
        XCTAssertEqual(plan.draws(at: 21).first?.key, "card.1")
        XCTAssertEqual(plan.draws(at: 65).first?.key, "card.0")
        XCTAssertEqual(Set(plan.cardPlacements), [.topRight, .center])
        plan.hasPlace = false
        XCTAssertTrue(plan.draws(at: 21).isEmpty)
        XCTAssertTrue(plan.cardPlacements.isEmpty)
    }

    func testLayoutAnchorsAndScaling() {
        // 1920x1080 target, card bitmap 400x200 drawn at 40 % of the short side: 432 px high, 864 wide.
        let r = OverlayLayout.rect(texWidth: 400, texHeight: 200, targetWidth: 1920, targetHeight: 1080, placement: .bottomLeft, size: .fractionOfShort(0.4))
        XCTAssertEqual(r.x0, -1 + 2 * 43.2 / 1920, accuracy: 1e-5)
        XCTAssertEqual((r.x1 - r.x0) * 1920 / 2, 864, accuracy: 0.01)
        XCTAssertEqual((r.y1 - r.y0) * 1080 / 2, 432, accuracy: 0.01)
        let c = OverlayLayout.rect(texWidth: 400, texHeight: 200, targetWidth: 1920, targetHeight: 1080, placement: .center, size: .fractionOfShort(0.4))
        XCTAssertEqual(c.x0, -(c.x1), accuracy: 1e-5)
        // Reference size: a 200 px high bitmap made for a 2160 short side is 100 px at 1080.
        let ref = OverlayLayout.rect(texWidth: 400, texHeight: 200, targetWidth: 1920, targetHeight: 1080, placement: .topRight, size: .referenceShort(2160))
        XCTAssertEqual((ref.y1 - ref.y0) * 1080 / 2, 100, accuracy: 0.01)
        XCTAssertEqual(ref.x1, 1 - 2 * 43.2 / 1920, accuracy: 1e-5)
        // Too wide: limited to 90 % of the width, aspect kept.
        let wide = OverlayLayout.rect(texWidth: 4000, texHeight: 200, targetWidth: 1000, targetHeight: 1000, placement: .center, size: .fractionOfShort(0.4))
        XCTAssertEqual((wide.x1 - wide.x0) * 1000 / 2, 900, accuracy: 0.01)
        XCTAssertEqual((wide.y1 - wide.y0) * 1000 / 2, 45, accuracy: 0.01)
    }

    func testCardKeyCodableAndSidecarBackCompat() throws {
        let k = key(12.5, .bottomCenter)
        XCTAssertEqual(try JSONDecoder().decode(LocationCardKey.self, from: JSONEncoder().encode(k)), k)
        let lenient = try JSONDecoder().decode(LocationCardKey.self, from: Data(#"{"time": 3, "placement": "nonsense"}"#.utf8))
        XCTAssertEqual(lenient.time, 3)
        XCTAssertEqual(lenient.placement, .bottomLeft)
        let p = ProjectSidecar(locationCards: [k], autoLocationCard: false)
        XCTAssertEqual(ProjectSidecar.decode(p.encoded()!), p)
        let old = ProjectSidecar.decode(Data(#"{"locationPlacement":"Centre"}"#.utf8))
        XCTAssertNil(old?.locationCards)
        XCTAssertNil(old?.autoLocationCard)
    }

    func testBundleBuildsOnlyNeededAlignments() {
        let info = PlaceInfo(latitude: 55, longitude: 12, country: "Denmark", place: "Nyhavn", altitude: 5)
        let plan = OverlayPlan(hasPlace: true, autoCard: true, autoPlacement: .topLeft, cardKeys: [key(5, .topLeft), key(20, .bottomLeft), key(40, .topRight)])
        let b = OverlayBundle.make(place: info, plan: plan, style: LocationCardStyle())
        XCTAssertEqual(Set(b.images.keys), ["card.-1", "card.1"])
        XCTAssertTrue(OverlayBundle.make(place: nil, plan: plan, style: LocationCardStyle()).images.isEmpty)
    }
}
