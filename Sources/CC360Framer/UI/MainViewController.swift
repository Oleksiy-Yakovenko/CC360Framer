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
        // Container that pins the stack to its real edges (not the safe area), so the preview runs underneath the
        // transparent unified toolbar instead of leaving window-gray strip above it. Only the player area (and the
        // strip under the toolbar) is black; the controls below keep the window background.
        let container = NSView()
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdrop)
        Kit.pin(stack, to: container)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: player.view.bottomAnchor),
        ])
        view = container
    }
}

private extension NSToolbarItem.Identifier {
    static let appTitle = NSToolbarItem.Identifier("appTitle")
    static let export = NSToolbarItem.Identifier("export")
    static let inspectorSeparator = NSToolbarItem.Identifier("inspectorSeparator")
    static let inspector = NSToolbarItem.Identifier("inspector")
}

/// Main view controller: the left sidebar | preview column | right sidebar split view and the window toolbar.
final class MainViewController: NSSplitViewController, NSToolbarDelegate {
    let model: PlayerModel
    let center: CenterViewController
    private let inspectorItem: NSSplitViewItem
    private var exportItem: NSToolbarItem?
    private var bag = Set<AnyCancellable>()
    /// Called with every file dropped on the window; set by the window controller.
    var openURLs: (([URL]) -> Void)?

    init(model: PlayerModel) {
        self.model = model
        center = CenterViewController(model: model)
        let left = NSSplitViewItem(sidebarWithViewController: LeftSidebarViewController(model: model))
        left.minimumThickness = 200
        left.maximumThickness = 400
        let middle = NSSplitViewItem(viewController: center)
        middle.minimumThickness = 420
        inspectorItem = NSSplitViewItem(inspectorWithViewController: RightSidebarViewController(model: model))
        inspectorItem.minimumThickness = 280
        inspectorItem.maximumThickness = 360
        super.init(nibName: nil, bundle: nil)
        let split = DropSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "MainSplit"
        split.onDrop = { [weak self] urls in self?.openURLs?(urls) }
        splitView = split
        addSplitViewItem(left)
        addSplitViewItem(middle)
        addSplitViewItem(inspectorItem)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateToolbar() } }
            .store(in: &bag)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Menu shortcuts and mouse look need the preview to be the first responder.
        view.window?.makeFirstResponder(center.player.lookView)
    }

    func toggleInspector() { inspectorItem.animator().isCollapsed.toggle() }

    // MARK: Toolbar

    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        // The separators follow the split view dividers, so the items sit above the pane they belong to.
        [.toggleSidebar, .sidebarTrackingSeparator, .appTitle, .export, .flexibleSpace, .inspectorSeparator, .flexibleSpace, .inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
        let delegate = NSApp.delegate
        switch id {
        case .appTitle:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = Kit.title("CC360Framer")
            return item
        case .export:
            let item = button(id, "Export…", "arrowshape.up.fill", "Export the reframed video with the selected preset", delegate, #selector(AppDelegate.exportDocument))
            exportItem = item
            updateToolbar()
            return item
        case .inspectorSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 1)
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

    /// Export turns into Cancel while an export runs, and is disabled until a file is open.
    private func updateToolbar() {
        if model.duration > 0 { view.window?.title = model.title }
        guard let item = exportItem else { return }
        if let p = model.exportProgress {
            item.label = "Cancel"
            item.image = Kit.symbol("xmark.circle", "Cancel export")
            item.toolTip = "Cancel the export (\(Int(p * 100))%)"
            item.isEnabled = true
        } else {
            item.label = "Export…"
            item.image = Kit.symbol("arrowshape.up.fill", "Export")
            item.toolTip = "Export the reframed video with the selected preset"
            item.isEnabled = model.duration > 0
        }
    }
}
