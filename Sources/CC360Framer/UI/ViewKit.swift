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
    static let captionID = NSUserInterfaceItemIdentifier("caption")

    static func title(_ s: String) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return f
    }

    static func caption(_ s: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: s)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        f.identifier = captionID
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

    /// Vertical stack pinned under the toolbar with 12 pt insets. Popups, progress bars and captions get the full width.
    @discardableResult
    static func sidebarStack(in view: NSView, _ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        for v in views where v is NSPopUpButton || v is NSProgressIndicator || v.identifier == captionID {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
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
