import AppKit
import Combine

/// Split view that accepts a dropped video file.
final class DropSplitView: NSSplitView {
    var onDrop: (([URL]) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// Preview, playback controls and keyframe buttons stacked in the middle pane.
/// Its view is pinned below the toolbar by `SidebarLayout.addContent`, so it needs no safe-area handling itself.
final class CenterViewController: NSViewController {
    let player: PlayerViewController
    let transport: TransportViewController
    let timelineBar: TimelineBarViewController

    init(model: PlayerModel) {
        player = PlayerViewController(model: model)
        transport = TransportViewController(model: model)
        timelineBar = TimelineBarViewController(model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        for child in [player, transport, timelineBar] { addChild(child) }
        let stack = NSStackView(views: [player.view, transport.view, timelineBar.view])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        player.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        player.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        for v in [transport.view, timelineBar.view] {
            v.setContentHuggingPriority(.required, for: .vertical)
            v.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        // The black backdrop covers only the player; the controls below keep the window background.
        let container = NSView()
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdrop)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: player.view.bottomAnchor),
        ])
        view = container
    }
}

/// Plain view painted with the window background (the sidebars' wrappers).
final class WindowColoredView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.set()
        dirtyRect.fill()
    }
}

/// Window layout shared with the PCBDesigner project: the split view fills the whole content view and every pane is
/// wrapped by a view controller whose child is pinned to the window's content layout guide (the area below the
/// unified toolbar). Nothing then extends under the toolbar and the toolbar sections line up with the panes.
@MainActor
enum SidebarLayout {
    private static func topLayoutGuide(of window: NSWindow) -> NSLayoutAnchor<NSLayoutYAxisAnchor>? {
        (window.contentLayoutGuide as? NSObject)?.value(forKey: "topAnchor") as? NSLayoutAnchor<NSLayoutYAxisAnchor>
    }

    static func makeSplitView(onDrop: @escaping ([URL]) -> Void) -> DropSplitView {
        let splitView = DropSplitView()
        splitView.dividerStyle = .thin
        splitView.isVertical = true
        splitView.onDrop = onDrop
        return splitView
    }

    /// Central item. The wrapper is needed for constraints purposes.
    static func contentItem(_ vc: NSViewController, to split: NSSplitViewController, window: NSWindow) -> NSSplitViewItem {
        let wrapper = NSViewController()
        wrapper.view = NSView()
        wrapper.addChild(vc)
        wrapper.view.addSubview(vc.view)
        let item = NSSplitViewItem(viewController: wrapper)
        item.minimumThickness = 420
        split.addSplitViewItem(item)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            vc.view.leadingAnchor.constraint(equalTo: wrapper.view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: wrapper.view.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: wrapper.view.bottomAnchor),
        ]
        constraints.append(topLayoutGuide(of: window).map { vc.view.topAnchor.constraint(equalTo: $0) }
                           ?? vc.view.topAnchor.constraint(equalTo: wrapper.view.topAnchor))
        NSLayoutConstraint.activate(constraints)
        return item
    }

    /// Sidebar or inspector item. The content's own 12 pt inset stays the only inset: the child starts exactly at the
    /// content layout guide, so its safe area top is zero.
    static func sidebarItem(_ vc: NSViewController, inspector: Bool, min: CGFloat, max: CGFloat,
                            to split: NSSplitViewController, window: NSWindow) -> NSSplitViewItem {
        let wrapper = NSViewController(nibName: nil, bundle: nil)
        wrapper.view = WindowColoredView()
        wrapper.addChild(vc)
        wrapper.view.addSubview(vc.view)
        let item = inspector ? NSSplitViewItem(inspectorWithViewController: wrapper)
                             : NSSplitViewItem(sidebarWithViewController: wrapper)
        item.minimumThickness = min
        item.maximumThickness = max
        split.addSplitViewItem(item)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            vc.view.leadingAnchor.constraint(equalTo: wrapper.view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: wrapper.view.trailingAnchor),
            vc.view.bottomAnchor.constraint(equalTo: wrapper.view.bottomAnchor),
        ]
        constraints.append(topLayoutGuide(of: window).map { vc.view.topAnchor.constraint(equalTo: $0) }
                           ?? vc.view.topAnchor.constraint(equalTo: wrapper.view.topAnchor))
        NSLayoutConstraint.activate(constraints)
        return item
    }

    /// Fills the window with the split view and applies the toolbar style.
    static func install(_ splitView: NSSplitView, in window: NSWindow, toolbar: NSToolbar) {
        guard let view = window.contentView else { fatalError("Window doesn't have a content view") }
        window.toolbar = toolbar
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        view.addSubview(splitView)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}

private extension NSToolbarItem.Identifier {
    static let toggleLeft = NSToolbarItem.Identifier("toggleLeft")
    static let appTitle = NSToolbarItem.Identifier("appTitle")
    static let leftSeparator = NSToolbarItem.Identifier("leftSeparator")
    static let rightSeparator = NSToolbarItem.Identifier("rightSeparator")
    static let inspector = NSToolbarItem.Identifier("inspector")
}

/// Main view controller: the left sidebar | preview column | right inspector split view and the window toolbar.
/// Its view is not the window's content view controller's view; `install(in:)` puts the split view into the window.
final class MainViewController: NSSplitViewController, NSToolbarDelegate {
    let model: PlayerModel
    let center: CenterViewController
    private let dropSplitView: DropSplitView
    private var leftItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    private var titleLabel: NSTextField?
    private var bag = Set<AnyCancellable>()
    /// Called with every file dropped on the window; set by the window controller.
    var openURLs: (([URL]) -> Void)?
    /// Called when the user moved a divider or collapsed a pane (not while the saved layout is applied).
    var onLayoutChange: (() -> Void)?
    private var applyingLayout = false

    init(model: PlayerModel) {
        self.model = model
        center = CenterViewController(model: model)
        var drop: (([URL]) -> Void)?
        dropSplitView = SidebarLayout.makeSplitView { drop?($0) }
        super.init(nibName: nil, bundle: nil)
        drop = { [weak self] urls in self?.openURLs?(urls) }
        splitView = dropSplitView
        view = dropSplitView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Builds the panes, puts the split view into the window and sets the divider positions from `layout`.
    /// The window must already have its final size and toolbar delegate (`makeToolbar`) available.
    func install(in window: NSWindow, layout: SplitLayout = .standard) {
        SidebarLayout.install(dropSplitView, in: window, toolbar: makeToolbar())
        leftItem = SidebarLayout.sidebarItem(LeftSidebarViewController(model: model), inspector: false, min: 200, max: 400,
                                             to: self, window: window)
        _ = SidebarLayout.contentItem(center, to: self, window: window)
        let right = RightSidebarViewController(model: model)
        // Selecting an object on the timeline (click, previous / next) shows its settings in the Inspector tab.
        center.transport.onSelectItem = { [weak right] in right?.showInspector() }
        center.timelineBar.onSelectItem = { [weak right] in right?.showInspector() }
        inspectorItem = SidebarLayout.sidebarItem(right, inspector: true, min: 280, max: 600,
                                                  to: self, window: window)
        window.contentView?.layoutSubtreeIfNeeded()
        apply(layout)
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: dropSplitView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.applyingLayout else { return }
                self.onLayoutChange?()
            }
        }

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateToolbar() } }
            .store(in: &bag)
        // Menu shortcuts and mouse look need the preview to be the first responder.
        window.makeFirstResponder(center.player.lookView)
    }

    private func apply(_ layout: SplitLayout) {
        applyingLayout = true
        defer { applyingLayout = false }
        let l = layout.fitted(totalWidth: Double(dropSplitView.bounds.width))
        leftItem?.isCollapsed = l.leftCollapsed
        inspectorItem?.isCollapsed = l.inspectorCollapsed
        if !l.leftCollapsed { dropSplitView.setPosition(CGFloat(l.left), ofDividerAt: 0) }
        if !l.inspectorCollapsed { dropSplitView.setPosition(dropSplitView.bounds.width - CGFloat(l.inspector), ofDividerAt: 1) }
    }

    /// The pane widths now; a collapsed pane keeps the width of `base`.
    func currentLayout(base: SplitLayout) -> SplitLayout {
        var l = base
        l.leftCollapsed = leftItem?.isCollapsed ?? false
        l.inspectorCollapsed = inspectorItem?.isCollapsed ?? false
        if !l.leftCollapsed, let w = leftItem?.viewController.view.frame.width, w > 0 { l.left = Double(w) }
        if !l.inspectorCollapsed, let w = inspectorItem?.viewController.view.frame.width, w > 0 { l.inspector = Double(w) }
        return l
    }

    func toggleInspector() { inspectorItem?.animator().isCollapsed.toggle() }
    @objc func toggleLeft(_ sender: Any?) { leftItem?.animator().isCollapsed.toggle() }

    // MARK: Toolbar

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The tracking separators follow the split view dividers, so the items sit above the pane they belong to.
        [.toggleLeft, .leftSeparator, .appTitle, .flexibleSpace, .rightSeparator, .flexibleSpace, .inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let delegate = NSApp.delegate
        switch id {
        case .leftSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: dropSplitView, dividerIndex: 0)
        case .rightSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: dropSplitView, dividerIndex: 1)
        case .toggleLeft:
            return button(id, "Sidebar", "sidebar.left", "Show or hide the left sidebar", delegate, #selector(AppDelegate.toggleSidebar))
        case .appTitle:
            let item = NSToolbarItem(itemIdentifier: id)
            let label = Kit.title(ToolbarTitle.text(appName: "CC360Framer", fileName: model.title))
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            titleLabel = label
            item.view = label
            return item
        case .inspector:
            return button(id, "Inspector", "sidebar.right", "Show or hide the right sidebar", delegate, #selector(AppDelegate.toggleInspector))
        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ symbol: String, _ tip: String,
                        _ target: AnyObject?, _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = tip
        item.image = Kit.symbol(symbol, label)
        item.isBordered = true
        item.target = target
        item.action = action
        return item
    }

    /// Keeps the toolbar title ("CC360Framer - file") and the hidden window title current.
    private func updateToolbar() {
        if model.duration > 0 { view.window?.title = model.title }
        let text = ToolbarTitle.text(appName: "CC360Framer", fileName: model.duration > 0 ? model.title : nil)
        if let label = titleLabel, label.stringValue != text {
            label.stringValue = text
            label.invalidateIntrinsicContentSize()
        }
    }
}
