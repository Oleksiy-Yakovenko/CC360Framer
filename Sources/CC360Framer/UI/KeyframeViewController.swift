import AppKit

/// Keyframe editing buttons below the playback controls, plus the status line.
final class KeyframeViewController: ModelViewController {
    private var previousButton = NSButton()
    private var nextButton = NSButton()
    private var setButton = NSButton()
    private var deleteButton = NSButton()
    private var clearButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")

    override func loadView() {
        view = NSView()
        previousButton = Kit.symbolButton("backward.end.fill", tip: "Previous keyframe", target: self, action: #selector(previous))
        nextButton = Kit.symbolButton("forward.end.fill", tip: "Next keyframe", target: self, action: #selector(next))
        setButton = Kit.button("Set key", tip: "Keyframe the current view at the playhead (K)", target: self, action: #selector(setKey))
        deleteButton = Kit.button("Delete key", tip: "Delete the selected keyframe (Delete)", target: self, action: #selector(deleteKey))
        clearButton = Kit.button("Clear keys", tip: "Remove all keyframes", target: self, action: #selector(clearKeys))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Buttons pinned to the leading inset (same as the transport row); the status label fills the rest.
        let buttons = NSStackView(views: [previousButton, nextButton, setButton, deleteButton, clearButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [buttons, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            buttons.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            statusLabel.leadingAnchor.constraint(equalTo: buttons.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
        ])
    }

    override func refresh() {
        let hasKeys = !model.keyframes.isEmpty
        previousButton.isEnabled = hasKeys
        nextButton.isEnabled = hasKeys
        setButton.isEnabled = model.duration > 0
        deleteButton.isEnabled = model.selectedKey != nil
        clearButton.isEnabled = hasKeys
        statusLabel.stringValue = model.statusText ?? ""
    }

    @objc private func setKey() { model.setKey() }
    @objc private func deleteKey() { confirmDeleteKey() }
    @objc private func clearKeys() {
        confirm("Clear all keyframes?", "This removes every keyframe. You can undo it with Edit > Undo.", button: "Clear keys") { [model] in model.clearKeys() }
    }

    /// Asks before deleting the selected keyframe (also used by the Delete menu item).
    func confirmDeleteKey() {
        guard model.selectedKey != nil else { return }
        confirm("Delete the selected keyframe?", "You can undo it with Edit > Undo.", button: "Delete key") { [model] in model.deleteSelectedKey() }
    }

    private func confirm(_ message: String, _ info: String, button: String, _ action: @escaping () -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = info
        let destructive = alert.addButton(withTitle: button)
        destructive.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
    }
    @objc private func previous() { jump(forward: false) }
    @objc private func next() { jump(forward: true) }

    /// Jumps to the nearest keyframe before or after the playhead.
    private func jump(forward: Bool) {
        let t = model.position
        let target = forward ? model.keyframes.first { $0.time > t + 0.15 }
                             : model.keyframes.last { $0.time < t - 0.15 }
        if let target { model.select(target) }
    }
}
