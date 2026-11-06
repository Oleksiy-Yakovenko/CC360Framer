import AppKit

/// Welcome window with the recent documents, as in PCBDesigner: borderless with rounded corners, closes with Escape.
@MainActor
final class WelcomeWindow: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        isRestorable = false
        title = "Welcome to CC360Framer"
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { close() }
}

@MainActor
final class WelcomeWindowController: NSWindowController {
    private let content: WelcomeViewController

    /// - Parameters:
    ///   - recents: the recent file URLs, most recent first.
    ///   - open: opens one of them.
    ///   - openOther: shows the open panel.
    init(recents: @escaping () -> [URL], open: @escaping (URL) -> Void, openOther: @escaping () -> Void) {
        content = WelcomeViewController(recents: recents, open: open, openOther: openOther)
        super.init(window: WelcomeWindow())
        content.close = { [weak self] in self?.close() }
        window?.contentViewController = content
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func showWindow(_ sender: Any?) {
        content.reload()
        window?.center()
        super.showWindow(sender)
    }
}

/// Table that opens the selected row with Return or Enter.
final class WelcomeTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0, let doubleAction else {
            super.keyDown(with: event)
            return
        }
        NSApp.sendAction(doubleAction, to: target, from: self)
    }
}

final class WelcomeRowView: NSTableRowView {
    static let horizontalInset: CGFloat = 8
    static let separatorInset: CGFloat = 52

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        (isEmphasized ? NSColor.selectedContentBackgroundColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.horizontalInset, dy: 0), xRadius: 8, yRadius: 8).fill()
    }

    override func drawSeparator(in dirtyRect: NSRect) {
        guard !isSelected, !isNextRowSelected else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: Self.separatorInset, y: isFlipped ? bounds.maxY - 1 : 0,
               width: bounds.width - Self.separatorInset - Self.horizontalInset - 4, height: 1).fill()
    }
}

final class WelcomeCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("WelcomeCellView")
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let locationField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        nameField.font = .systemFont(ofSize: 14)
        locationField.font = .systemFont(ofSize: 11)
        for f in [nameField, locationField] {
            f.lineBreakMode = .byTruncatingMiddle
            f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let text = NSStackView(views: [nameField, locationField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for v in [iconView, text] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: WelcomeRowView.separatorInset),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }

    func configure(_ entry: RecentDocumentEntry) {
        iconView.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        nameField.stringValue = entry.name
        locationField.stringValue = entry.location
        toolTip = entry.url.path
    }

    private func applyColors() {
        let selected = backgroundStyle == .emphasized
        nameField.textColor = selected ? .alternateSelectedControlTextColor : .labelColor
        locationField.textColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
    }
}

@MainActor
final class WelcomeViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var close: (() -> Void)?
    private let recents: () -> [URL]
    private let openRecent: (URL) -> Void
    private let openOther: () -> Void

    private let windowSize = NSSize(width: 480, height: 600)
    private let nameField = NSTextField(labelWithString: "Welcome to CC360Framer")
    private let versionField = NSTextField(labelWithString: "")
    private let emptyField = NSTextField(labelWithString: "No Recent Documents")
    private let tableView = WelcomeTableView()
    private var entries: [RecentDocumentEntry] = []

    init(recents: @escaping () -> [URL], open: @escaping (URL) -> Void, openOther: @escaping () -> Void) {
        self.recents = recents
        openRecent = open
        self.openOther = openOther
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let background = NSBox()
        background.boxType = .custom
        background.borderWidth = 0
        background.cornerRadius = 26
        background.fillColor = .windowBackgroundColor
        background.contentViewMargins = .zero
        background.frame = NSRect(origin: .zero, size: windowSize)
        view = background
        preferredContentSize = windowSize
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let closeButton = Kit.symbolButton("xmark", tip: "Close", target: self, action: #selector(closeAction))
        closeButton.bezelStyle = .circular

        let icon = NSImageView(image: NSApp.applicationIconImage)
        nameField.font = .systemFont(ofSize: 20, weight: .bold)
        versionField.font = .systemFont(ofSize: 13)
        versionField.textColor = .secondaryLabelColor
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String { versionField.stringValue = "Version \(v)" }
        emptyField.font = .systemFont(ofSize: 13)
        emptyField.textColor = .secondaryLabelColor

        tableView.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document")))
        tableView.headerView = nil
        tableView.rowHeight = 46
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openAction)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

        let listBox = NSBox()
        listBox.boxType = .custom
        listBox.borderWidth = 0
        listBox.cornerRadius = 14
        listBox.fillColor = NSColor.labelColor.withAlphaComponent(0.04)
        listBox.contentViewMargins = .zero
        listBox.contentView = scroll

        let openButton = Kit.button("Open…", tip: "Choose a .360 file to open", target: self, action: #selector(openOtherAction))
        openButton.keyEquivalent = ""

        for item in [closeButton, icon, nameField, versionField, listBox, emptyField, openButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 19),
            closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 19),
            closeButton.widthAnchor.constraint(equalToConstant: 38),
            closeButton.heightAnchor.constraint(equalToConstant: 38),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 70),
            icon.widthAnchor.constraint(equalToConstant: 98),
            icon.heightAnchor.constraint(equalToConstant: 98),
            nameField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            nameField.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 14),
            versionField.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            versionField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 2),
            listBox.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            listBox.widthAnchor.constraint(equalToConstant: 360),
            listBox.topAnchor.constraint(equalTo: versionField.bottomAnchor, constant: 24),
            listBox.bottomAnchor.constraint(equalTo: openButton.topAnchor, constant: -16),
            emptyField.centerXAnchor.constraint(equalTo: listBox.centerXAnchor),
            emptyField.centerYAnchor.constraint(equalTo: listBox.centerYAnchor),
            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
        ])
    }

    /// Re-reads the recent documents (the window is reused between showings).
    func reload() {
        entries = RecentDocumentEntry.entries(from: recents())
        emptyField.isHidden = !entries.isEmpty
        tableView.reloadData()
        if tableView.selectedRow < 0, !entries.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(tableView)
        reload()
    }

    @objc private func closeAction() { close?() }

    @objc private func openOtherAction() { openOther() }

    @objc private func openAction() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard entries.indices.contains(row) else { return }
        openRecent(entries[row].url)
        close?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: WelcomeCellView.identifier, owner: nil) as? WelcomeCellView ?? WelcomeCellView()
        cell.configure(entries[row])
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { WelcomeRowView() }
}
