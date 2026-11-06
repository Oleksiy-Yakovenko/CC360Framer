import Foundation

/// Snapshot-based undo: each undoable change records the state before it; undo restores it and
/// registers the inverse, so redo works. Pure Foundation, no UI, so it is unit-testable.
@MainActor
final class SnapshotUndo<State> {
    let manager = UndoManager()
    private let capture: () -> State
    private let restore: (State) -> Void

    /// - Parameters:
    ///   - capture: reads the current state.
    ///   - restore: writes a state back (called by undo and redo; should also persist).
    init(capture: @escaping () -> State, restore: @escaping (State) -> Void) {
        self.capture = capture
        self.restore = restore
        manager.groupsByEvent = false
    }

    /// Runs `change` and registers one undo step named `name` that returns to the state before it.
    func perform(_ name: String, _ change: () -> Void) {
        let before = capture()
        change()
        register(before, name)
    }

    /// Registers an undo step to `before` for a change that was already made.
    func register(_ before: State, _ name: String) {
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { $0.apply(before, name) }
        manager.setActionName(name)
        manager.endUndoGrouping()
    }

    private func apply(_ state: State, _ name: String) {
        let current = capture()
        restore(state)
        // Registered while undoing this becomes the redo step, and vice versa.
        manager.registerUndo(withTarget: self) { $0.apply(current, name) }
        manager.setActionName(name)
    }
}
