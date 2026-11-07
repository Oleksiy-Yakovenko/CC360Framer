import AppKit

/// Bottom bar: a popup picks the active timeline (keyframes, cuts, ...); the buttons act on it through its `TimelineAdapter`.
final class TimelineBarViewController: ModelViewController {
    private var popup = NSPopUpButton()
    private var previousButton = NSButton()
    private var nextButton = NSButton()
    private var addButton = NSButton()
    private var deleteButton = NSButton()
    private var clearButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private var shownKind: TimelineKind?

    override func loadView() {
        view = NSView()
        popup = Kit.popup(TimelineKind.allCases.map(\.rawValue), tip: "Timeline to edit: keyframes (camera), cuts (removed parts), location cards, captions, audio clips", target: self, action: #selector(kindChosen))
        previousButton = Kit.symbolButton("backward.end.fill", tip: "Previous item", target: self, action: #selector(previous))
        nextButton = Kit.symbolButton("forward.end.fill", tip: "Next item", target: self, action: #selector(next))
        addButton = Kit.button("Add", target: self, action: #selector(add))
        deleteButton = Kit.button("Delete", target: self, action: #selector(deleteSelected))
        clearButton = Kit.button("Clear", target: self, action: #selector(clear))
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Controls pinned to the leading inset (same as the transport row); the status label fills the rest.
        let buttons = NSStackView(views: [popup, previousButton, nextButton, addButton, deleteButton, clearButton])
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
        let t = model.timeline
        if shownKind != t.kind {
            shownKind = t.kind
            popup.selectItem(at: TimelineKind.allCases.firstIndex(of: t.kind) ?? 0)
            addButton.title = t.addTitle; addButton.toolTip = t.addTip
            deleteButton.title = t.deleteTitle; deleteButton.toolTip = t.deleteTip
            clearButton.title = t.clearTitle; clearButton.toolTip = t.clearTip
        }
        previousButton.isEnabled = !t.items.isEmpty
        nextButton.isEnabled = !t.items.isEmpty
        addButton.isEnabled = t.canAdd
        deleteButton.isEnabled = t.canDelete
        clearButton.isEnabled = t.canClear
        statusLabel.stringValue = model.statusText ?? ""
    }

    @objc private func kindChosen() { model.activeTimeline = TimelineKind.allCases[popup.indexOfSelectedItem] }
    @objc private func add() { model.timeline.add() }
    @objc private func deleteSelected() { confirmDelete() }
    @objc private func clear() {
        let t = model.timeline
        confirm(t.clearConfirm, button: t.clearTitle) { t.clear() }
    }

    /// Asks before deleting the selected item (also used by the Delete menu item).
    func confirmDelete() {
        let t = model.timeline
        guard t.canDelete else { return }
        confirm(t.deleteConfirm, button: t.deleteTitle) { t.deleteSelected() }
    }

    private func confirm(_ text: (String, String), button: String, _ action: @escaping () -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.0
        alert.informativeText = text.1
        let destructive = alert.addButton(withTitle: button)
        destructive.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
    }

    @objc private func previous() { jump(forward: false) }
    @objc private func next() { jump(forward: true) }

    /// Jumps to the nearest item before or after the playhead.
    private func jump(forward: Bool) {
        let t = model.timeline
        if let target = TimelineNav.neighbor(t.items, of: model.position, forward: forward) { t.select(target.id) }
    }
}
