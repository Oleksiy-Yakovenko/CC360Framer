import XCTest
@testable import CCAppCore

final class OverlayTests: XCTestCase {
    func testAlphaEnvelope() {
        XCTAssertEqual(LocationOverlay.alpha(at: -1), 0)
        XCTAssertEqual(LocationOverlay.alpha(at: 0), 0)
        XCTAssertEqual(LocationOverlay.alpha(at: 0.3), 0.5, accuracy: 1e-5)
        XCTAssertEqual(LocationOverlay.alpha(at: 5), 1)
        XCTAssertEqual(LocationOverlay.alpha(at: LocationOverlay.visibleSeconds - 0.3), 0.5, accuracy: 1e-5)
        XCTAssertEqual(LocationOverlay.alpha(at: LocationOverlay.visibleSeconds), 0)
        XCTAssertEqual(LocationOverlay.alpha(at: 60), 0)
    }

    func testPlacementAnchors() {
        XCTAssertEqual(OverlayPlacement.topLeft.anchor.x, -1)
        XCTAssertEqual(OverlayPlacement.topLeft.anchor.y, 1)
        XCTAssertEqual(OverlayPlacement.center.anchor.x, 0)
        XCTAssertEqual(OverlayPlacement.center.anchor.y, 0)
        XCTAssertEqual(OverlayPlacement.bottomRight.anchor.x, 1)
        XCTAssertEqual(OverlayPlacement.bottomRight.anchor.y, -1)
    }

    func testCancelFlag() {
        let f = CancelFlag()
        XCTAssertFalse(f.isSet)
        f.set()
        XCTAssertTrue(f.isSet)
    }
}
