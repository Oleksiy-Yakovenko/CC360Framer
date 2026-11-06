import AppKit
import Combine

/// Base for the view controllers: rebuilds its controls from the model whenever the model changes.
class ModelViewController: NSViewController {
    let model: PlayerModel
    private var bag = Set<AnyCancellable>()

    init(model: PlayerModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // objectWillChange fires before the change; hopping to the next run loop pass sees the new values.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &bag)
        refresh()
    }

    /// Copy the model state into the controls. Must be cheap and idempotent: it runs on every model change.
    func refresh() {}
}

/// One row of a `Kit.grid`.
@MainActor
final class GridRow {
    let views: [NSView]
    let fill: Bool, top: Bool, merged: Bool
    fileprivate(set) var row: NSGridRow?
    init(views: [NSView], fill: Bool, top: Bool, merged: Bool = false) {
        self.views = views; self.fill = fill; self.top = top; self.merged = merged
    }
    var isHidden: Bool {
        get { row?.isHidden ?? false }
        set { row?.isHidden = newValue }
    }
}

/// What a sidebar tab segment shows: its SF Symbol, or the title when the symbol is unavailable.
enum TabItem {
    enum Display: Equatable { case symbol, title(String) }

    static func display(symbolAvailable: Bool, title: String) -> Display {
        symbolAvailable ? .symbol : .title(title)
    }
}

/// Small helpers for building controls in code.
@MainActor
enum Kit {
    /// Mark a view with this identifier to make `sidebarStack` stretch it to the full width.
    static let fullWidthID = NSUserInterfaceItemIdentifier("fullWidth")

    /// Bold section title. Explanations belong in `tip`, not in a subtitle label.
    static func title(_ s: String, tip: String? = nil) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        f.toolTip = tip
        return f
    }

    static func button(_ title: String, tip: String? = nil, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.toolTip = tip
        return b
    }

    static func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    static func symbolButton(_ name: String, tip: String, target: AnyObject, action: Selector) -> NSButton {
        let b = NSButton(image: symbol(name, tip), target: target, action: action)
        b.bezelStyle = .rounded
        b.toolTip = tip
        return b
    }

    static func popup(_ titles: [String], tip: String, target: AnyObject, action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.toolTip = tip
        p.target = target
        p.action = action
        return p
    }

    /// Vertical stack pinned under the toolbar with 12 pt insets. Popups, progress bars and wide rows (`fullWidthID`) get the full width.
    @discardableResult
    static func sidebarStack(in view: NSView, _ views: [NSView], topAnchor: NSLayoutYAxisAnchor? = nil) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor ?? view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        for v in views where v is NSPopUpButton || v is NSProgressIndicator || v.identifier == fullWidthID {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// Width of the label column of every settings grid (labels are right-aligned, so each sits next to its control; all pages share the width so values line up).
    static let labelColumnWidth: CGFloat = 88

    /// A row `Label | control`. `fill`: the control stretches to the right edge; false keeps its own (fixed) size at the controls column.
    /// `top`: align to the top of a tall control (text view).
    static func row(_ label: String, _ control: NSView, tip: String? = nil, fill: Bool = true, top: Bool = false) -> GridRow {
        let l = NSTextField(labelWithString: label)
        l.toolTip = tip
        l.alignment = .right
        l.lineBreakMode = .byClipping
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return GridRow(views: [l, control], fill: fill, top: top)
    }

    /// A row with an empty label cell: checkboxes (the text is the checkbox title) and buttons start at the controls column.
    static func checkRow(_ control: NSView) -> GridRow {
        GridRow(views: [NSGridCell.emptyContentView, control], fill: false, top: false)
    }

    /// A view spanning both columns (section title inside a grid).
    static func fullRow(_ view: NSView) -> GridRow {
        GridRow(views: [view, NSGridCell.emptyContentView], fill: false, top: false, merged: true)
    }

    /// Two-column grid (label column, controls column). Hide a row with `GridRow.isHidden`, not by hiding its views.
    static func grid(_ rows: [GridRow]) -> NSGridView {
        let g = NSGridView(views: rows.map(\.views))
        g.translatesAutoresizingMaskIntoConstraints = false
        g.columnSpacing = 8
        g.rowSpacing = 6
        g.identifier = fullWidthID
        g.column(at: 0).width = labelColumnWidth
        for (i, r) in rows.enumerated() {
            let gr = g.row(at: i)
            r.row = gr
            gr.yPlacement = r.top ? .top : .center
            if r.merged {
                gr.mergeCells(in: NSRange(location: 0, length: 2))
                g.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .leading
            } else {
                g.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .trailing
                g.cell(atColumnIndex: 1, rowIndex: i).xPlacement = r.fill ? .fill : .leading
            }
        }
        return g
    }

    static func colorWell(_ color: NSColor, tip: String, target: AnyObject, action: Selector) -> NSColorWell {
        let w = NSColorWell(style: .minimal)
        w.color = color
        w.toolTip = tip
        w.target = target
        w.action = action
        w.widthAnchor.constraint(equalToConstant: 44).isActive = true
        w.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return w
    }

    /// A slider with an editable numeric field to its right (see `SliderField`); use it as the control of `Kit.row`.
    static func sliderRow(_ slider: NSSlider, decimals: Int, step: Double, target: AnyObject, action: Selector) -> SliderField {
        SliderField(slider: slider, decimals: decimals, step: step, target: target, action: action)
    }

    /// Editable combo box with preset sizes: pick one or type any number (see `SizeInput`); the action fires on selection, Return and leaving the field.
    static func sizeCombo(presets: [Double], tip: String, target: AnyObject, action: Selector) -> NSComboBox {
        let c = SizeComboBox()
        c.addItems(withObjectValues: presets.map(SizeInput.format))
        c.numberOfVisibleItems = presets.count
        c.completes = false
        c.toolTip = tip
        c.target = target
        c.action = action
        c.delegate = c
        c.widthAnchor.constraint(equalToConstant: 84).isActive = true
        return c
    }

    /// Shows `value` unless the user is typing in the combo box.
    static func setSize(_ c: NSComboBox, _ value: Double) {
        if c.currentEditor() == nil { c.stringValue = SizeInput.format(value) }
    }

    /// The size picked or typed in the combo box, clamped; unparsable text goes back to `current` (and is shown again).
    /// Never trusts `indexOfSelectedItem`: it stays on the last preset after a non-preset value is typed.
    static func readSize(_ c: NSComboBox, range: ClosedRange<Double>, step: Double = 1, current: Double) -> Double {
        let picked = (c as? SizeComboBox)?.takePick()
        let text = SizeInput.chosenText(pickedItem: picked, editorText: c.currentEditor()?.string, stringValue: c.stringValue)
        let v = SizeInput.parse(text, range: range, step: step) ?? current
        c.stringValue = SizeInput.format(v)
        return v
    }

    /// Size combo box that remembers a list pick (the selection notification arrives before the text field is updated) and
    /// fires its action when editing ends (tabbing away does not always send it).
    @MainActor
    final class SizeComboBox: NSComboBox, NSComboBoxDelegate {
        private var pick: String?
        func takePick() -> String? { defer { pick = nil }; return pick }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            pick = objectValueOfSelectedItem as? String
            // The control sends its action itself; if it did not consume the pick by the next turn, send it.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pick != nil, let action = self.action else { return }
                self.sendAction(action, to: self.target)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard pick == nil, let action else { return }
            sendAction(action, to: target)   // a no-op downstream when the value did not change
        }
    }

    /// Popup listing the installed font families; the represented object of each item is the family name.
    static func fontPopup(selected: String? = nil, tip: String, target: AnyObject, action: Selector) -> NSPopUpButton {
        let p = popup(NSFontManager.shared.availableFontFamilies, tip: tip, target: target, action: action)
        if let selected { p.selectItem(withTitle: selected) }
        return p
    }

    /// Sidebar tab container: a segmented control over a content area that shows one page at a time.
    /// Pages are plain views (e.g. built with `sidebarStack`'s sibling, `pageStack`).
    @MainActor
    final class TabContainer: NSView {
        private let segmented = NSSegmentedControl()
        private let content = NSView()
        private(set) var pages: [NSView] = []
        var selectedIndex: Int { segmented.selectedSegment }

        init(_ tabs: [(title: String, symbol: String, tip: String, page: NSView)]) {
            super.init(frame: .zero)
            pages = tabs.map(\.page)
            segmented.segmentCount = tabs.count
            for (i, t) in tabs.enumerated() {
                let image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.tip)
                switch TabItem.display(symbolAvailable: image != nil, title: t.title) {
                case .symbol: segmented.setImage(image, forSegment: i)
                case .title(let title): segmented.setLabel(title, forSegment: i)
                }
                segmented.setImageScaling(.scaleProportionallyDown, forSegment: i)
                segmented.setToolTip(t.tip, forSegment: i)
            }
            segmented.segmentStyle = .automatic
            segmented.trackingMode = .selectOne
            segmented.target = self
            segmented.action = #selector(changed)
            segmented.selectedSegment = 0
            segmented.translatesAutoresizingMaskIntoConstraints = false
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(segmented)
            addSubview(content)
            NSLayoutConstraint.activate([
                segmented.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
                segmented.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                segmented.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                content.topAnchor.constraint(equalTo: segmented.bottomAnchor, constant: 8),
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            for p in pages { Kit.pin(p, to: content) }
            select(0)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func select(_ index: Int) {
            guard pages.indices.contains(index) else { return }
            segmented.selectedSegment = index
            for (i, p) in pages.enumerated() { p.isHidden = i != index }
        }

        @objc private func changed() { select(segmented.selectedSegment) }
    }

    /// Vertical stack of controls with 12 pt side insets, for use as a tab page (no safe-area top offset).
    static func pageStack(_ views: [NSView]) -> NSView {
        let page = NSView()
        sidebarStack(in: page, views, topAnchor: page.topAnchor)
        return page
    }

    static func pin(_ v: NSView, to parent: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            v.topAnchor.constraint(equalTo: parent.topAnchor),
            v.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    nonisolated static func time(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}


/// Slider plus an editable value field (plain number, no unit). Dragging the slider updates the field; typing a number and
/// pressing Return or leaving the field clamps to the slider range, rounds to `step`, moves the slider and sends the same
/// action as a drag. The owner reads `slider.doubleValue` in its action and calls `setValue(_:)` when the model changes.
@MainActor
final class SliderField: NSStackView {
    let slider: NSSlider
    let field = NSTextField()
    private let decimals: Int
    private let step: Double
    private weak var ownerTarget: AnyObject?
    private var ownerAction: Selector

    init(slider: NSSlider, decimals: Int, step: Double, target: AnyObject, action: Selector) {
        self.slider = slider
        self.decimals = decimals
        self.step = step
        ownerTarget = target
        ownerAction = action
        super.init(frame: .zero)
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.target = self
        field.action = #selector(fieldCommitted)
        field.setContentHuggingPriority(.required, for: .horizontal)
        field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        field.stringValue = SizeInput.format(slider.doubleValue, decimals: decimals)
        addArrangedSubview(slider)
        addArrangedSubview(field)
        spacing = 6
        distribution = .fill
        orientation = .horizontal
    }
    required init?(coder: NSCoder) { fatalError() }

    override var toolTip: String? {
        didSet { field.toolTip = toolTip }
    }

    var isEnabled: Bool {
        get { slider.isEnabled }
        set { slider.isEnabled = newValue; field.isEnabled = newValue }
    }

    /// Sets the slider and shows the value, unless the user is typing in the field.
    func setValue(_ v: Double) {
        slider.doubleValue = v
        if field.currentEditor() == nil { field.stringValue = SizeInput.format(v, decimals: decimals) }
    }

    private func send() {
        NSApp.sendAction(ownerAction, to: ownerTarget, from: slider)
    }

    @objc private func sliderMoved() {
        field.stringValue = SizeInput.format(slider.doubleValue, decimals: decimals)
        send()
    }

    @objc private func fieldCommitted() {
        let range = slider.minValue...slider.maxValue
        guard let v = SizeInput.parse(field.stringValue, range: range, step: step) else {
            field.stringValue = SizeInput.format(slider.doubleValue, decimals: decimals)   // invalid: revert
            return
        }
        slider.doubleValue = v
        field.stringValue = SizeInput.format(v, decimals: decimals)
        send()
    }
}
