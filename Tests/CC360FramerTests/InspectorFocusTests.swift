import XCTest
@testable import CC360Framer

final class InspectorFocusTests: XCTestCase {
    func testSwitchingItemResets() {
        XCTAssertTrue(InspectorFocus.shouldResetFields(shown: UUID(), selected: UUID()))
    }
    func testSameItemKeepsTyping() {
        let id = UUID()
        XCTAssertFalse(InspectorFocus.shouldResetFields(shown: id, selected: id))
    }
    func testFirstSelectionResets() {
        XCTAssertTrue(InspectorFocus.shouldResetFields(shown: nil, selected: UUID()))
    }
    func testNoSelectionDoesNotReset() {
        XCTAssertFalse(InspectorFocus.shouldResetFields(shown: UUID(), selected: nil))
        XCTAssertFalse(InspectorFocus.shouldResetFields(shown: UUID?.none, selected: nil))
    }
}
