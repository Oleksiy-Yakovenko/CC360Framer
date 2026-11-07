import XCTest
import AppKit
@testable import CCAppCore

@MainActor
final class TextEditingTests: XCTestCase {
    func testTextViewAndFieldEditorCountAsEditing() {
        XCTAssertTrue(TextEditing.isEditing(NSTextView()))
        XCTAssertFalse(TextEditing.isEditing(NSView()))
    }

    func testScrollableTextViewHasWidthTrackingContainer() {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        XCTAssertTrue(tv.isEditable)
        XCTAssertTrue(tv.textContainer?.widthTracksTextView ?? false)
    }
}
