import XCTest
@testable import CC360Framer

@MainActor
final class UndoTests: XCTestCase {
    private struct S: Equatable { var keys: [Int]; var sel: Int? }

    func testUndoRedoRestoresKeysAndSelection() {
        var state = S(keys: [1], sel: nil)
        let undo = SnapshotUndo<S>(capture: { state }, restore: { state = $0 })
        undo.perform("Set Key") { state = S(keys: [1, 2], sel: 2) }
        undo.perform("Delete Key") { state = S(keys: [1], sel: nil) }
        XCTAssertEqual(undo.manager.undoActionName, "Delete Key")

        undo.manager.undo()
        XCTAssertEqual(state, S(keys: [1, 2], sel: 2))
        XCTAssertEqual(undo.manager.redoActionName, "Delete Key")
        undo.manager.undo()
        XCTAssertEqual(state, S(keys: [1], sel: nil))
        XCTAssertFalse(undo.manager.canUndo)

        undo.manager.redo()
        XCTAssertEqual(state, S(keys: [1, 2], sel: 2))
        undo.manager.redo()
        XCTAssertEqual(state, S(keys: [1], sel: nil))
        XCTAssertFalse(undo.manager.canRedo)
    }

    func testRestoreCallbackRunsOnUndoAndRedo() {
        var state = 0
        var restored: [Int] = []
        let undo = SnapshotUndo<Int>(capture: { state }, restore: { state = $0; restored.append($0) })
        undo.perform("Change") { state = 5 }
        undo.manager.undo()
        undo.manager.redo()
        XCTAssertEqual(restored, [0, 5])
    }

    func testNewChangeClearsRedo() {
        var state = 0
        let undo = SnapshotUndo<Int>(capture: { state }, restore: { state = $0 })
        undo.perform("A") { state = 1 }
        undo.manager.undo()
        XCTAssertTrue(undo.manager.canRedo)
        undo.perform("B") { state = 2 }
        XCTAssertFalse(undo.manager.canRedo)
    }
}
