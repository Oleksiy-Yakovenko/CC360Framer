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
        XCTAssertEqual(r.x0, -1 + 2 * 43.0 / 1920, accuracy: 1e-5)   // margin 43.2 px snapped to 43
        XCTAssertEqual((r.x1 - r.x0) * 1920 / 2, 864, accuracy: 0.01)
        XCTAssertEqual((r.y1 - r.y0) * 1080 / 2, 432, accuracy: 0.01)
        let c = OverlayLayout.rect(texWidth: 400, texHeight: 200, targetWidth: 1920, targetHeight: 1080, placement: .center, size: .fractionOfShort(0.4))
        XCTAssertEqual(c.x0, -(c.x1), accuracy: 1e-5)
        // Reference size: a 200 px high bitmap made for a 2160 short side is 100 px at 1080.
        let ref = OverlayLayout.rect(texWidth: 400, texHeight: 200, targetWidth: 1920, targetHeight: 1080, placement: .topRight, size: .referenceShort(2160))
        XCTAssertEqual((ref.y1 - ref.y0) * 1080 / 2, 100, accuracy: 0.01)
        XCTAssertEqual(ref.x1, 1 - 2 * 43.0 / 1920, accuracy: 1e-5)
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

    func testScaleFactorsForTargets() {
        XCTAssertEqual(OverlayScale.cardFactor(targetShort: 1080), 1, accuracy: 1e-9)
        XCTAssertEqual(OverlayScale.cardFactor(targetShort: 720), 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(OverlayScale.cardFactor(targetShort: 2160), 2, accuracy: 1e-9)
        XCTAssertEqual(OverlayScale.cardFactor(targetShort: 0), 1.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(OverlayScale.short(width: 3840, height: 2160), 2160)
        XCTAssertEqual(OverlayScale.short(width: 1080, height: 1920), 1080)
        XCTAssertEqual(OverlayScale.short(width: 0, height: 100), 1)
    }

    func testBitmapSizeFollowsTargetShort() throws {
        let info = PlaceInfo(latitude: 55, longitude: 12, country: "Denmark", altitude: 5, city: "Copenhagen")
        let h = { (short: Int) -> Int in
            LocationOverlay.image(for: info, placement: .bottomLeft, scale: OverlayScale.cardFactor(targetShort: short))?.height ?? 0
        }
        // Bitmap height is proportional to the target short side (rounding of text metrics aside).
        XCTAssertEqual(Double(h(2160)) / Double(h(1080)), 2, accuracy: 0.05)
        XCTAssertEqual(Double(h(720)) / Double(h(1080)), 2.0 / 3, accuracy: 0.05)
        XCTAssertEqual(LocationOverlay.image(for: info, placement: .bottomLeft)?.height, h(1080))
    }

    func testLayoutIsOneToOneWhenBuiltForTarget() {
        for (w, h) in [(1280.0, 720.0), (1920, 1080), (3840, 2160), (1080, 1920)] {
            let short = Float(min(w, h))
            let r = OverlayLayout.rect(texWidth: 600, texHeight: 301, targetWidth: Float(w), targetHeight: Float(h), placement: .bottomLeft, size: .referenceShort(short))
            XCTAssertEqual((r.x1 - r.x0) * Float(w) / 2, 600, accuracy: 1e-2)
            XCTAssertEqual((r.y1 - r.y0) * Float(h) / 2, 301, accuracy: 1e-2)
            // Origin on a whole pixel.
            let px = (r.x0 + 1) * Float(w) / 2, py = (r.y0 + 1) * Float(h) / 2
            XCTAssertEqual(px, px.rounded(), accuracy: 1e-2)
            XCTAssertEqual(py, py.rounded(), accuracy: 1e-2)
        }
        // Centre placement with odd leftover pixels still snaps to the grid.
        let c = OverlayLayout.rect(texWidth: 601, texHeight: 301, targetWidth: 1920, targetHeight: 1080, placement: .center, size: .referenceShort(1080))
        let cx = (c.x0 + 1) * 960
        XCTAssertEqual(cx, cx.rounded(), accuracy: 1e-2)
    }

    func testDrawsUseBuiltShortAsReference() {
        let plan = OverlayPlan(hasPlace: true, autoCard: true, autoPlacement: .bottomLeft, captions: [Caption(start: 0, end: 5, text: "x")])
        let d = plan.draws(at: 2, builtShort: 720)
        XCTAssertEqual(d.count, 2)
        XCTAssertTrue(d.allSatisfy { $0.size == .referenceShort(720) })
    }

    func testCardCacheInvalidatesOnTargetStyleAndFields() {
        let info = PlaceInfo(latitude: 55, longitude: 12, country: "Denmark", altitude: 5, city: "Copenhagen")
        let cache = CardImageCache()
        var style = LocationCardStyle(), fields = LocationCardFields()
        func build(_ short: Int) -> [String: CGImage] { cache.images(place: info, placements: [.bottomLeft, .topLeft, .center], style: style, fields: fields, targetShort: short) }
        let a = build(1080)
        XCTAssertEqual(Set(a.keys), ["card.-1", "card.0"])
        XCTAssertEqual(cache.renders, 2)
        let b = build(1080)
        XCTAssertEqual(cache.renders, 2)
        XCTAssertTrue(a["card.-1"] === b["card.-1"])
        let c = build(1440)   // preview resized: re-rasterised
        XCTAssertEqual(cache.renders, 4)
        XCTAssertGreaterThan(c["card.-1"]!.height, a["card.-1"]!.height)
        style.baseSize = 80
        _ = build(1440)
        XCTAssertEqual(cache.renders, 6)
        fields.street = true
        _ = build(1440)
        XCTAssertEqual(cache.renders, 8)
    }

    func testCaptionCacheInvalidatesOnTarget() throws {
        let cache = CaptionImageCache()
        let cap = Caption(start: 0, end: 3, text: "Hello")
        let a = cache.images(for: [cap], style: CaptionStyle(), targetShort: 1080)
        _ = cache.images(for: [cap], style: CaptionStyle(), targetShort: 1080)
        XCTAssertEqual(cache.renders, 1)
        let b = cache.images(for: [cap], style: CaptionStyle(), targetShort: 2160)
        XCTAssertEqual(cache.renders, 2)
        let key = OverlayPlan.captionImageKey(cap.id)
        XCTAssertEqual(Double(b[key]!.height) / Double(a[key]!.height), 2, accuracy: 0.1)
    }

    func testBundleRecordsTargetShort() {
        let plan = OverlayPlan(captions: [Caption(start: 0, end: 1, text: "x")])
        XCTAssertEqual(OverlayBundle.make(place: nil, plan: plan, style: LocationCardStyle(), targetShort: 720).targetShort, 720)
    }

    /// The card's pixel height through the whole path (card keyframe, bundle, plan, layout) is proportional to baseSize.
    func testCardKeyframeHeightScalesWithBaseSize() {
        let info = PlaceInfo(latitude: 55, longitude: 12, country: "Denmark", altitude: 5, city: "Copenhagen", street: "Nyhavn", houseNumber: "7")
        var plan = OverlayPlan()
        plan.hasPlace = true
        plan.autoCard = false
        plan.cardKeys = [LocationCardKey(time: 90, placement: .topCenter)]
        func height(_ base: Double, short: Int = 1080) -> Float {
            let b = OverlayBundle.make(place: info, plan: plan, style: LocationCardStyle(baseSize: base), targetShort: short)
            let d = plan.draws(at: 92, builtShort: b.targetShort)
            XCTAssertEqual(d.count, 1)
            let img = b.images[d[0].key]!
            let r = OverlayLayout.rect(texWidth: img.width, texHeight: img.height, targetWidth: Float(short) * 16 / 9, targetHeight: Float(short),
                                       placement: d[0].placement, size: d[0].size)
            return (r.y1 - r.y0) / 2 * Float(short)
        }
        let h24 = height(24), h64 = height(64), h128 = height(128)
        XCTAssertGreaterThan(h64, h24 * 1.8)
        XCTAssertGreaterThan(h128, h64 * 1.5)
        XCTAssertEqual(height(64, short: 540), height(64) / 2, accuracy: 3)
    }

    // MARK: place resolution

    @MainActor
    func testResolveStaleCacheShownBeforeGeocoderAnswers() async throws {
        let fix = Telemetry.GPSFix(latitude: 1, longitude: 2, altitude: 9)
        let stale = try JSONDecoder().decode(PlaceInfo.self, from: Data(#"{"latitude":1,"longitude":2,"country":"DK","place":"Nyhavn, Town"}"#.utf8))
        let fresh = PlaceInfo(latitude: 1, longitude: 2, country: "DK", city: "Town")
        var events: [String] = []
        let r = await PlaceInfo.resolve(fix: fix, cached: stale, geocoder: { _ in events.append("geocode"); return fresh },
                                        provisional: { p in events.append("provisional:\(p.place ?? "-"):\(p.altitude ?? -1)") })
        XCTAssertEqual(events, ["provisional:Nyhavn, Town:9.0", "geocode"])   // shown first, with the fix's altitude
        XCTAssertEqual(r.info, fresh)
        XCTAssertTrue(r.save)
        // Failed refresh keeps the legacy cache and saves nothing.
        let failed = await PlaceInfo.resolve(fix: fix, cached: stale, geocoder: { _ in nil })
        XCTAssertEqual(failed.info, stale.withAltitude(of: fix))
        XCTAssertFalse(failed.save)
    }

    @MainActor func testResolveFreshAndMissingCache() async {
        let fix = Telemetry.GPSFix(latitude: 1, longitude: 2, altitude: 9)
        let fresh = PlaceInfo(latitude: 1, longitude: 2, country: "DK", altitude: 9, city: "Town")
        var called = false
        let a = await PlaceInfo.resolve(fix: fix, cached: fresh, geocoder: { _ in called = true; return nil })
        XCTAssertFalse(called)
        XCTAssertEqual(a.info, fresh)
        XCTAssertFalse(a.save)
        var noAlt = fresh; noAlt.altitude = nil
        let b = await PlaceInfo.resolve(fix: fix, cached: noAlt, geocoder: { _ in nil })
        XCTAssertTrue(b.save)   // altitude refreshed
        let c = await PlaceInfo.resolve(fix: fix, cached: nil, geocoder: { _ in nil })
        XCTAssertEqual(c.info, PlaceInfo(latitude: 1, longitude: 2, altitude: 9))
        XCTAssertFalse(c.save)
        let d = await PlaceInfo.resolve(fix: fix, cached: nil, geocoder: { _ in fresh })
        XCTAssertTrue(d.save)
    }

    func testWithTimeoutFallsBack() async {
        let slow = await PlaceInfo.withTimeout(0.05, fallback: "fallback") { try? await Task.sleep(nanoseconds: 5_000_000_000); return "late" }
        XCTAssertEqual(slow, "fallback")
        let quick = await PlaceInfo.withTimeout(2, fallback: "fallback") { "done" }
        XCTAssertEqual(quick, "done")
    }
}
