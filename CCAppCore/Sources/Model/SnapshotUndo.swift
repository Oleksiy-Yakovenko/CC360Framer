import Foundation

/// Snapshot-based undo: each undoable change records the state before it; undo restores it and
/// registers the inverse, so redo works. Pure Foundation, no UI, so it is unit-testable.
/// It owns no `UndoManager`: it registers on whichever manager `manager()` returns (the document's, see `VideoDocument`)
/// and leaves its configuration (event grouping) alone, so text views and other AppKit clients can share the manager.
@MainActor
final class SnapshotUndo<State> {
    private let manager: () -> UndoManager?
    private let capture: () -> State
    private let restore: (State) -> Void

    /// - Parameters:
    ///   - manager: the undo manager to register on right now; nil skips registration.
    ///   - capture: reads the current state.
    ///   - restore: writes a state back (called by undo and redo; should also persist).
    init(manager: @escaping () -> UndoManager?, capture: @escaping () -> State, restore: @escaping (State) -> Void) {
        self.manager = manager
        self.capture = capture
        self.restore = restore
    }

    /// Runs `change` and registers one undo step named `name` that returns to the state before it.
    func perform(_ name: String, _ change: () -> Void) {
        let before = capture()
        change()
        register(before, name)
    }

    /// Registers an undo step to `before` for a change that was already made.
    func register(_ before: State, _ name: String) {
        guard let m = manager() else { return }
        m.registerUndo(withTarget: self) { $0.apply(before, name) }
        m.setActionName(name)
    }

    private func apply(_ state: State, _ name: String) {
        let current = capture()
        restore(state)
        // Registered while undoing this becomes the redo step, and vice versa.
        guard let m = manager() else { return }
        m.registerUndo(withTarget: self) { $0.apply(current, name) }
        m.setActionName(name)
    }
}
