import XCTest
@testable import CC360Framer

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
