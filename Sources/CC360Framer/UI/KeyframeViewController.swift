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

        let row = NSStackView(views: [previousButton, nextButton, setButton, deleteButton, clearButton, statusLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
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
    @objc private func deleteKey() { model.deleteSelectedKey() }
    @objc private func clearKeys() { model.clearKeys() }
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
