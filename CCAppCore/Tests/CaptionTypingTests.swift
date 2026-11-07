import XCTest
import AppKit
@testable import CCAppCore

@MainActor
final class CaptionTypingTests: XCTestCase {
    private var keep: VideoDocument?
    private func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }

    private func textView(in v: NSView) -> NSTextView? {
        if let t = v as? NSTextView { return t }
        for s in v.subviews { if let t = textView(in: s) { return t } }
        return nil
    }

    private func setup() -> (PlayerModel, NSWindow, NSTextView) {
        let doc = VideoDocument()
        keep = doc
        let model = doc.model
        model.duration = 60
        model.addCaption()
        model.activeTimeline = .captions
        let vc = InspectorTabViewController(model: model)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let wc = NSWindowController(window: win)
        doc.addWindowController(wc)
        win.contentViewController = vc
        vc.view.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        win.layoutIfNeeded()
        spin()
        let tv = textView(in: vc.view)!
        XCTAssertTrue(win.makeFirstResponder(tv))
        return (model, win, tv)
    }

    func testTypingAndDeletingReachesModelAndSurvivesRefresh() {
        let (model, win, tv) = setup()
        XCTAssertTrue(win.firstResponder === tv)
        tv.selectAll(nil)
        XCTAssertTrue(tv.isEditable)
        tv.insertText("abc", replacementRange: tv.selectedRange())
        spin()
        XCTAssertEqual(tv.string, "abc")
        XCTAssertEqual(model.selectedCaptionValue?.text, "abc")
        tv.deleteBackward(nil)
        spin()
        XCTAssertEqual(tv.string, "ab")
        XCTAssertEqual(model.selectedCaptionValue?.text, "ab")
        tv.insertText("Z", replacementRange: tv.selectedRange())
        spin()
        XCTAssertEqual(tv.string, "abZ")
        XCTAssertEqual(tv.selectedRange().location, 3)
    }

    func testRealKeyEventsThroughWindow() {
        let (model, win, tv) = setup()
        func key(_ ch: String, _ code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                         context: nil, characters: ch, charactersIgnoringModifiers: ch, isARepeat: false, keyCode: code)!
                win.sendEvent(e)
            }
        }
        tv.selectAll(nil)
        key("a", 0); key("k", 40); key(" ", 49)
        spin()
        XCTAssertEqual(tv.string, "ak ")
        key("\u{7f}", 51)
        spin()
        XCTAssertEqual(tv.string, "ak")
        XCTAssertEqual(model.selectedCaptionValue?.text, "ak")
    }

    func testWindowAndDocumentShareTheDocumentsUndoManager() {
        let (model, win, tv) = setup()
        let doc = keep!
        XCTAssertTrue(doc.undoManager === model.undoManager)
        XCTAssertTrue(win.undoManager === doc.undoManager)
        XCTAssertTrue(tv.undoManager === doc.undoManager)
        // The Edit menu's undo:/redo: (nil target) find a responder in a document window.
        XCTAssertTrue(win.responds(to: Selector(("undo:"))) || tv.responds(to: Selector(("undo:"))))
    }

    func testUndoRevertsTypedText() {
        let (model, _, tv) = setup()
        let original = model.selectedCaptionValue!.text
        tv.selectAll(nil)
        tv.insertText("hello", replacementRange: tv.selectedRange())
        spin()
        XCTAssertEqual(model.selectedCaptionValue?.text, "hello")
        XCTAssertTrue(model.undoManager.canUndo)
        var n = 0
        while model.selectedCaptionValue?.text != original, model.undoManager.canUndo, n < 6 { model.undoManager.undo(); spin(); n += 1 }
        XCTAssertEqual(model.selectedCaptionValue?.text, original)
    }
}
