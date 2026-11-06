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

/// Small helpers for building controls in code.
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

    /// A label on the left and a control on the right.
    static func labeledRow(_ label: String, _ control: NSView, tip: String? = nil) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.toolTip = tip
        l.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [l, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.identifier = fullWidthID
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
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

        init(_ tabs: [(title: String, page: NSView)]) {
            super.init(frame: .zero)
            pages = tabs.map(\.page)
            segmented.segmentCount = tabs.count
            for (i, t) in tabs.enumerated() { segmented.setLabel(t.title, forSegment: i) }
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
                segmented.topAnchor.constraint(equalTo: topAnchor, constant: 12),
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

    static func time(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
