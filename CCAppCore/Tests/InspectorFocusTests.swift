import XCTest
@testable import CCAppCore

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

final class InspectorFocusAudioClipTests: XCTestCase {
    func testSwitchingAudioClipResets() {
        let a = AudioClip(start: 0, end: 3), b = AudioClip(start: 1, end: 4)
        XCTAssertTrue(InspectorFocus.shouldResetFields(shown: a.id, selected: b.id))
        XCTAssertFalse(InspectorFocus.shouldResetFields(shown: a.id, selected: a.id))
    }
}
