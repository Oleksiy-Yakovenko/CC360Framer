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

    func testMasterSwitchOffHidesEverything() {
        let info = PlaceInfo(latitude: 55, longitude: 12, country: "Denmark", city: "Copenhagen")
        var plan = OverlayPlan(hasPlace: true, showCard: false, autoCard: true, autoPlacement: .topLeft, cardKeys: [key(5, .topLeft)])
        XCTAssertTrue(plan.cardPlacements.isEmpty)
        XCTAssertTrue(plan.draws(at: 6).isEmpty)
        XCTAssertTrue(OverlayBundle.make(place: info, plan: plan, style: LocationCardStyle()).images.isEmpty)
        plan.cardKeys = []
        XCTAssertTrue(plan.draws(at: 1).isEmpty)
        plan.showCard = true
        XCTAssertEqual(plan.draws(at: 1).count, 1)
    }

    func testAllFieldsOffDrawsNoImage() {
        let info = PlaceInfo(latitude: 55, longitude: 12, country: "Denmark", altitude: 5, city: "Copenhagen")
        var f = LocationCardFields()
        f.country = false; f.city = false; f.coordinates = false; f.elevation = false
        XCTAssertNil(LocationOverlay.image(for: info, placement: .bottomLeft, fields: f))
        XCTAssertNotNil(LocationOverlay.image(for: info, placement: .bottomLeft))
    }

    func testLinesDefaultsMatchOldCard() {
        let old = PlaceInfo(latitude: 55.5, longitude: -12.25, country: "Denmark", place: "Nyhavn, Copenhagen", altitude: 5)
        XCTAssertEqual(old.lines(), ["Denmark", "Nyhavn, Copenhagen", "55.50000° N, 12.25000° W", "5 m"])
        XCTAssertEqual(old.cardLines().map(\.detail), [false, false, true, true])
        XCTAssertEqual(LocationCardStyle().sizes(lineCount: 4), [64, 44, 34, 34])
    }

    func testLinesCombinations() {
        let p = PlaceInfo(latitude: 1, longitude: 2, country: "DK", altitude: 7, city: "Town", street: "Main St", houseNumber: "12")
        for bits in 0..<64 {
            var f = LocationCardFields()
            f.country = bits & 1 != 0; f.city = bits & 2 != 0; f.street = bits & 4 != 0
            f.houseNumber = bits & 8 != 0; f.coordinates = bits & 16 != 0; f.elevation = bits & 32 != 0
            var want: [String] = []
            if f.country { want.append("DK") }
            if f.street { want.append(f.houseNumber ? "Main St 12" : "Main St") }
            if f.city { want.append("Town") }
            if f.coordinates { want.append(p.coordinateText) }
            if f.elevation { want.append("7 m") }
            XCTAssertEqual(p.lines(f), want, "bits \(bits)")
        }
        // Defaults: street and house number off.
        XCTAssertEqual(p.lines(), ["DK", "Town", p.coordinateText, "7 m"])
        // Missing parts are skipped; a number without a street is not shown.
        var f = LocationCardFields(); f.street = true; f.houseNumber = true
        let q = PlaceInfo(latitude: 1, longitude: 2, houseNumber: "12")
        XCTAssertEqual(q.lines(f), [q.coordinateText])
    }

    func testPlaceCodableAndStaleCache() throws {
        let old = #"{"latitude":1,"longitude":2,"country":"DK","place":"Nyhavn, Town"}"#
        let p = try JSONDecoder().decode(PlaceInfo.self, from: Data(old.utf8))
        XCTAssertTrue(p.isStale)
        XCTAssertNil(p.city)
        let fresh = PlaceInfo(latitude: 1, longitude: 2, country: "DK", city: "Town", street: "Main St", houseNumber: "1")
        XCTAssertFalse(fresh.isStale)
        XCTAssertEqual(try JSONDecoder().decode(PlaceInfo.self, from: JSONEncoder().encode(fresh)), fresh)
        XCTAssertFalse(PlaceInfo(latitude: 1, longitude: 2).isStale)
    }

    func testSidecarCardOptionsBackCompat() {
        let old = ProjectSidecar.decode(Data(#"{"locationPlacement":"Centre"}"#.utf8))
        XCTAssertNil(old?.showLocationCard)
        XCTAssertNil(old?.locationFields)
        var f = LocationCardFields(); f.street = true; f.country = false
        let p = ProjectSidecar(showLocationCard: false, locationFields: f)
        XCTAssertEqual(ProjectSidecar.decode(p.encoded()!), p)
        let partial = ProjectSidecar.decode(Data(#"{"locationFields":{"street":true}}"#.utf8))
        var want = LocationCardFields(); want.street = true
        XCTAssertEqual(partial?.locationFields, want)
    }
}
