import XCTest
@testable import CCAppCore

@MainActor
final class UndoTests: XCTestCase {
    private struct S: Equatable { var keys: [Int]; var sel: Int? }
    /// A default manager (event grouping on), as NSDocument creates it. Ends the "event" so steps do not merge.
    private let m = UndoManager()
    private func endEvent() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }

    func testUndoRedoRestoresKeysAndSelection() {
        var state = S(keys: [1], sel: nil)
        let undo = SnapshotUndo<S>(manager: { self.m }, capture: { state }, restore: { state = $0 })
        undo.perform("Set Key") { state = S(keys: [1, 2], sel: 2) }
        endEvent()
        undo.perform("Delete Key") { state = S(keys: [1], sel: nil) }
        XCTAssertEqual(m.undoActionName, "Delete Key")

        m.undo()
        XCTAssertEqual(state, S(keys: [1, 2], sel: 2))
        XCTAssertEqual(m.redoActionName, "Delete Key")
        m.undo()
        XCTAssertEqual(state, S(keys: [1], sel: nil))
        XCTAssertFalse(m.canUndo)

        m.redo()
        XCTAssertEqual(state, S(keys: [1, 2], sel: 2))
        m.redo()
        XCTAssertEqual(state, S(keys: [1], sel: nil))
        XCTAssertFalse(m.canRedo)
    }

    func testRestoreCallbackRunsOnUndoAndRedo() {
        var state = 0
        var restored: [Int] = []
        let undo = SnapshotUndo<Int>(manager: { self.m }, capture: { state }, restore: { state = $0; restored.append($0) })
        undo.perform("Change") { state = 5 }
        m.undo()
        m.redo()
        XCTAssertEqual(restored, [0, 5])
    }

    func testNewChangeClearsRedo() {
        var state = 0
        let undo = SnapshotUndo<Int>(manager: { self.m }, capture: { state }, restore: { state = $0 })
        undo.perform("A") { state = 1 }
        m.undo()
        XCTAssertTrue(m.canRedo)
        undo.perform("B") { state = 2 }
        XCTAssertFalse(m.canRedo)
    }

    func testNilProviderDoesNotCrashAndStillChanges() {
        var state = 0
        let undo = SnapshotUndo<Int>(manager: { nil }, capture: { state }, restore: { state = $0 })
        undo.perform("A") { state = 1 }
        XCTAssertEqual(state, 1)
    }

    func testSharedProviderIsOneStackWithActionNames() {
        var a = 0, b = 0
        let ua = SnapshotUndo<Int>(manager: { self.m }, capture: { a }, restore: { a = $0 })
        let ub = SnapshotUndo<Int>(manager: { self.m }, capture: { b }, restore: { b = $0 })
        ua.perform("Change A") { a = 1 }
        endEvent()
        ub.perform("Change B") { b = 1 }
        XCTAssertEqual(m.undoActionName, "Change B")
        m.undo()
        XCTAssertEqual(b, 0); XCTAssertEqual(a, 1)
        XCTAssertEqual(m.undoActionName, "Change A")
        m.undo()
        XCTAssertEqual(a, 0)
    }

    func testDoesNotChangeGroupingConfiguration() {
        let undo = SnapshotUndo<Int>(manager: { self.m }, capture: { 0 }, restore: { _ in })
        undo.perform("A") {}
        XCTAssertTrue(m.groupsByEvent)
    }

    func testModelUsesProvidedManagerElseFallback() {
        let model = PlayerModel()
        let fallback = model.undoManager
        XCTAssertTrue(model.undoManager === fallback)
        let custom = UndoManager()
        model.undoManagerProvider = { custom }
        XCTAssertTrue(model.undoManager === custom)
        model.undoManagerProvider = { nil }
        XCTAssertTrue(model.undoManager === fallback)
    }
}

/// Documents are viewers whose edits go to the sidecars: they must never count as edited (no save prompt on close/quit).
@MainActor
final class DocumentNeverEditedTests: XCTestCase {
    func testUndoRegistrationDoesNotMarkDocumentEdited() {
        let doc = VideoDocument()
        let m = doc.undoManager!
        var value = 0
        func set(_ v: Int) {
            let old = value
            value = v
            m.registerUndo(withTarget: doc) { _ in set(old) }
        }
        m.beginUndoGrouping()
        set(1)
        m.endUndoGrouping()
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertFalse(doc.hasUnautosavedChanges)
        m.undo()
        XCTAssertEqual(value, 0)
        XCTAssertFalse(doc.isDocumentEdited)
        m.redo()
        XCTAssertEqual(value, 1)
        XCTAssertFalse(doc.isDocumentEdited)
        doc.updateChangeCount(.changeDone)
        doc.updateChangeCount(.changeUndone)
        XCTAssertFalse(doc.isDocumentEdited)
        XCTAssertFalse(doc.hasUnautosavedChanges)
    }

    func testModelEditThroughDocumentManagerStaysClean() {
        let doc = VideoDocument()
        doc.model.setCardStyle(LocationCardStyle(baseSize: 77))
        doc.undoManager!.undo()
        XCTAssertFalse(doc.isDocumentEdited)
    }

    func testCanCloseWithoutAsking() {
        final class Target: NSObject {
            var answer: Bool?
            @objc func document(_ d: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) { answer = shouldClose }
        }
        let doc = VideoDocument()
        doc.updateChangeCount(.changeDone)
        let t = Target()
        doc.canClose(withDelegate: t, shouldClose: #selector(Target.document(_:shouldClose:contextInfo:)), contextInfo: nil)
        XCTAssertEqual(t.answer, true)
    }

    func testPendingDragIsFlushedOnClose() {
        var s = DirectionLock.Settle()
        XCTAssertFalse(s.takePending())
        s.noteDrag(at: 1)
        XCTAssertTrue(s.takePending())
        XCTAssertFalse(s.takePending())
    }

    /// Undo and redo of a card style write the project sidecar again (the restore closure saves).
    func testUndoRedoOfCardStyleIsSaved() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("undo-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let v = d.appendingPathComponent("a.360")
        let model = PlayerModel()
        model.setSourceURLForTesting(v)
        let original = model.cardStyle
        model.setCardStyle(LocationCardStyle(baseSize: 91))
        XCTAssertEqual(ProjectSidecar.load(for: v).locationStyle?.baseSize, 91)
        model.undoManager.undo()
        XCTAssertEqual(ProjectSidecar.load(for: v).locationStyle, original)
        model.undoManager.redo()
        XCTAssertEqual(ProjectSidecar.load(for: v).locationStyle?.baseSize, 91)
    }
}
