import XCTest
@testable import CC360Framer

final class CaptionTests: XCTestCase {
    func testDefaultStyle() {
        let s = CaptionStyle()
        XCTAssertEqual(s.placement, .bottomCenter)
        XCTAssertNil(s.fontName)
        XCTAssertEqual(s.fill, CardColor(r: 1, g: 1, b: 1))
        XCTAssertEqual(s.stroke, CardColor(r: 0, g: 0, b: 0))
        XCTAssertGreaterThan(s.strokeWidth, 0)
        XCTAssertTrue(CaptionStyle.sizeRange.contains(s.size))
    }

    func testOverridesResolve() {
        var base = CaptionStyle(fontName: "Menlo", size: 0.05)
        XCTAssertEqual(CaptionOverrides().resolved(over: base), base)
        let o = CaptionOverrides(fontName: CaptionStyle.systemFontName, size: 0.08, fill: CardColor(r: 1, g: 0, b: 0), strokeWidth: 0, placement: .topLeft)
        let r = o.resolved(over: base)
        XCTAssertNil(r.fontName)   // explicit system font
        XCTAssertEqual(r.size, 0.08)
        XCTAssertEqual(r.fill, CardColor(r: 1, g: 0, b: 0))
        XCTAssertEqual(r.stroke, base.stroke)   // inherited
        XCTAssertEqual(r.strokeWidth, 0)
        XCTAssertEqual(r.placement, .topLeft)
        // Inheriting follows later changes of the global style.
        base.fontName = "Courier"
        XCTAssertEqual(CaptionOverrides(size: 0.1).resolved(over: base).fontName, "Courier")
        XCTAssertEqual(CaptionOverrides(fontName: "Menlo").resolved(over: base).fontName, "Menlo")
        // Out-of-range sizes are clamped.
        XCTAssertEqual(CaptionOverrides(size: 5).resolved(over: base).size, CaptionStyle.sizeRange.upperBound)
        XCTAssertEqual(CaptionOverrides(size: 0).resolved(over: base).size, CaptionStyle.sizeRange.lowerBound)
        XCTAssertTrue(CaptionOverrides().isEmpty)
        XCTAssertFalse(o.isEmpty)
    }

    func testAlphaFades() {
        let c = Caption(start: 10, end: 14, text: "x")
        XCTAssertEqual(c.alpha(at: 9.9), 0)
        XCTAssertEqual(c.alpha(at: 10), 0)
        XCTAssertEqual(c.alpha(at: 10.1), 0.5, accuracy: 1e-5)
        XCTAssertEqual(c.alpha(at: 12), 1)
        XCTAssertEqual(c.alpha(at: 13.9), 0.5, accuracy: 1e-4)
        XCTAssertEqual(c.alpha(at: 14), 0)
        // Short captions fade for at most half their length.
        let short = Caption(start: 0, end: 0.2, text: "x")
        XCTAssertEqual(short.alpha(at: 0.1), 1, accuracy: 1e-5)
    }

    func testActiveCaptions() {
        let a = Caption(start: 1, end: 4, text: "a"), b = Caption(start: 6, end: 9, text: "b"), blank = Caption(start: 1, end: 4, text: "  \n")
        let list = [b, blank, a]
        XCTAssertTrue(CaptionLogic.active(list, at: 0.5).isEmpty)
        XCTAssertEqual(CaptionLogic.active(list, at: 2).map(\.caption.text), ["a"])   // blank text never shows
        XCTAssertTrue(CaptionLogic.active(list, at: 5).isEmpty)
        XCTAssertEqual(CaptionLogic.active(list, at: 7).map(\.caption.text), ["b"])
        // Overlapping captions are both active, in start order.
        let o = [Caption(start: 3, end: 8, text: "late"), Caption(start: 2, end: 8, text: "early")]
        XCTAssertEqual(CaptionLogic.active(o, at: 5).map(\.caption.text), ["early", "late"])
    }

    func testRegionEditingRules() throws {
        let r = try XCTUnwrap(RegionEdit.add([Caption](), at: 5, duration: 60, make: { Caption(start: $0, end: $1) }))
        XCTAssertEqual(r.added.end - r.added.start, RegionEdit.defaultLength)
        XCTAssertNil(RegionEdit.add(r.regions, at: 6, duration: 60, make: { Caption(start: $0, end: $1) }))
        let moved = RegionEdit.moveEdge(r.regions, id: r.added.id, edge: .end, to: 100, duration: 60)
        XCTAssertEqual(moved[0].end, 60)
    }

    func testPlanDrawsCaptionsAndCardTogether() {
        let cap = Caption(start: 2, end: 8, text: "hello", overrides: CaptionOverrides(placement: .topCenter))
        let plan = OverlayPlan(hasPlace: true, autoCard: true, autoPlacement: .bottomLeft, cardKeys: [],
                               captions: [cap, Caption(start: 20, end: 24, text: "later")], captionStyle: CaptionStyle())
        let d = plan.draws(at: 4)
        XCTAssertEqual(d.map(\.key), ["card.-1", OverlayPlan.captionImageKey(cap.id)])
        XCTAssertEqual(d[1].placement, .topCenter)
        XCTAssertEqual(d[1].size, .referenceShort(Float(CaptionOverlay.referenceShort)))
        XCTAssertEqual(plan.draws(at: 12).count, 0)
        XCTAssertEqual(plan.draws(at: 21).count, 1)
        // Captions work without a GPS place.
        var noPlace = plan; noPlace.hasPlace = false
        XCTAssertEqual(noPlace.draws(at: 4).count, 1)
    }

    func testCaptionPlacementUsesGlobalStyleUnlessOverridden() {
        var style = CaptionStyle(); style.placement = .topRight
        let plain = Caption(start: 0, end: 5, text: "a")
        let plan = OverlayPlan(captions: [plain], captionStyle: style)
        XCTAssertEqual(plan.draws(at: 2).first?.placement, .topRight)
    }

    func testImageCacheRendersOnlyOnChange() {
        let cache = CaptionImageCache()
        let a = Caption(start: 0, end: 3, text: "Hello\nworld"), b = Caption(start: 4, end: 7, text: "Two")
        var style = CaptionStyle()
        let first = cache.images(for: [a, b], style: style)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(cache.renders, 2)
        let again = cache.images(for: [a, b], style: style)   // same input: no new bitmaps, same objects
        XCTAssertEqual(cache.renders, 2)
        XCTAssertTrue(again[OverlayPlan.captionImageKey(a.id)] === first[OverlayPlan.captionImageKey(a.id)])
        var a2 = a; a2.text = "Changed"
        _ = cache.images(for: [a2, b], style: style)
        XCTAssertEqual(cache.renders, 3)
        // An override that does not change the resolved style costs nothing; a global change re-renders both.
        var b2 = b; b2.overrides = CaptionOverrides(size: style.size)
        _ = cache.images(for: [a2, b2], style: style)
        XCTAssertEqual(cache.renders, 3)
        style.fill = CardColor(r: 1, g: 1, b: 0)
        _ = cache.images(for: [a2, b2], style: style)
        XCTAssertEqual(cache.renders, 5)
        // Removed and blank captions drop out.
        XCTAssertTrue(cache.images(for: [Caption(start: 0, end: 1, text: " ")], style: style).isEmpty)
    }

    func testImageSizeFollowsTextAndStyle() throws {
        var style = CaptionStyle()
        let one = try XCTUnwrap(CaptionOverlay.image(text: "Hello", style: style))
        let two = try XCTUnwrap(CaptionOverlay.image(text: "Hello\nHello", style: style))
        XCTAssertGreaterThan(two.height, one.height)
        style.size = 0.1
        let big = try XCTUnwrap(CaptionOverlay.image(text: "Hello", style: style))
        XCTAssertGreaterThan(big.height, one.height)
        XCTAssertGreaterThan(big.width, one.width)
    }

    func testCodableBackCompat() throws {
        let c = Caption(start: 1, end: 3, text: "Hi\nthere", overrides: CaptionOverrides(fontName: "Menlo", size: 0.07, fill: CardColor(r: 0, g: 1, b: 0), placement: .center))
        XCTAssertEqual(try JSONDecoder().decode(Caption.self, from: JSONEncoder().encode(c)), c)
        // Missing optional keys, unknown placement and a damaged override block still load.
        let lenient = try JSONDecoder().decode(Caption.self, from: Data(#"{"start": 1, "end": 2, "overrides": {"placement": "nowhere", "size": "big"}}"#.utf8))
        XCTAssertEqual(lenient.text, "")
        XCTAssertTrue(lenient.overrides?.isEmpty ?? true)
        XCTAssertEqual(try JSONDecoder().decode(CaptionStyle.self, from: Data("{}".utf8)), CaptionStyle())
        XCTAssertEqual(try JSONDecoder().decode(CaptionStyle.self, from: Data(#"{"size": 0.09, "placement": "Top left"}"#.utf8)),
                       CaptionStyle(size: 0.09, placement: .topLeft))
        let p = ProjectSidecar(captions: [c], captionStyle: CaptionStyle(fontName: "Menlo"))
        XCTAssertEqual(ProjectSidecar.decode(p.encoded()!), p)
        let old = ProjectSidecar.decode(Data(#"{"locationPlacement":"Centre","cuts":[]}"#.utf8))
        XCTAssertNil(old?.captions)
        XCTAssertNil(old?.captionStyle)
    }

    func testStyleDefaultsPersistence() {
        let d = UserDefaults(suiteName: "cc360.test.\(UUID().uuidString)")!
        XCTAssertEqual(CaptionStyle.loadDefaults(d), CaptionStyle())
        let s = CaptionStyle(fontName: "Menlo", size: 0.08, strokeWidth: 3, placement: .topCenter)
        s.saveDefaults(d)
        XCTAssertEqual(CaptionStyle.loadDefaults(d), s)
    }
}
