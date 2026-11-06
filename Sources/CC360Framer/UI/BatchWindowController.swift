import AppKit
import Combine
import UniformTypeIdentifiers

/// Table that forwards Delete / Backspace to a handler.
private final class BatchTable: NSTableView {
    var onDelete: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
    }
}

/// The Batch Processing window: a list of files (drop files and folders, reorder, remove), the batch options and the
/// shared `ExportSettingsView`, with Start / Pause. One instance, owned by the `AppDelegate`.
@MainActor
final class BatchWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let runner = BatchRunner()
    private let table = BatchTable()
    private var bag = Set<AnyCancellable>()
    private let rowType = NSPasteboard.PasteboardType("dev.cc360framer.batch-row")

    private let startButton = NSButton()
    private var addButton = NSButton(), removeButton = NSButton(), clearButton = NSButton(), clearDoneButton = NSButton()
    private let forceCheck = NSButton(checkboxWithTitle: "Force re-analyse", target: nil, action: nil)
    private let exportCheck = NSButton(checkboxWithTitle: "Export", target: nil, action: nil)
    private var stylePopup = NSPopUpButton()
    private var qualityPopup = NSPopUpButton()
    private let folderButton = NSButton()
    private let folderLabel = NSTextField(labelWithString: "")
    private let settingsView = ExportSettingsView()
    private let progress = NSProgressIndicator()
    private let summary = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Batch Processing"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 460)
        window.setFrameAutosaveName("BatchWindow")
        super.init(window: window)
        window.delegate = self
        build()
        runner.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            .store(in: &bag)
        runner.onStop = { [weak self] in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Files opened from outside (e.g. dropped on the Dock icon) can be added through here.
    func add(_ urls: [URL]) { runner.add(urls) }

    // MARK: Layout

    private func build() {
        guard let content = window?.contentView else { return }

        table.addTableColumn({ let c = NSTableColumn(identifier: .init("name")); c.title = "File"; c.minWidth = 160; c.width = 360; return c }())
        table.addTableColumn({ let c = NSTableColumn(identifier: .init("status")); c.title = "Status"; c.minWidth = 120; c.width = 180; return c }())
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.registerForDraggedTypes([.fileURL, rowType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.draggingDestinationFeedbackStyle = .gap
        table.onDelete = { [weak self] in self?.removeSelected() }
        table.toolTip = "Drop .360 files or folders here (folders are searched recursively). Drag rows to reorder; Delete removes the selected rows."
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        addButton = Kit.button("Add…", tip: "Add .360 files or folders", target: self, action: #selector(addFiles))
        removeButton = Kit.button("Remove", tip: "Remove the selected files from the list (Delete key)", target: self, action: #selector(removeSelectedAction))
        clearDoneButton = Kit.button("Clear Finished", tip: "Remove the files that are done", target: self, action: #selector(clearFinished))
        clearButton = Kit.button("Clear", tip: "Remove all files from the list (the file being processed stays)", target: self, action: #selector(clearAll))
        let listButtons = NSStackView(views: [addButton, removeButton, clearDoneButton, clearButton])
        listButtons.spacing = 8

        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startPause)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [progress, summary, startButton])
        bottom.spacing = 12
        progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let left = NSStackView(views: [scroll, listButtons])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        scroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true

        // Right column: options and the shared export settings.
        forceCheck.target = self; forceCheck.action = #selector(optionsChanged)
        forceCheck.toolTip = "Analyse every file again and rebuild its camera path, replacing existing keyframes. Off: files with an analysis keep it (and their keyframes, also hand-edited ones); files without one are analysed."
        exportCheck.target = self; exportCheck.action = #selector(optionsChanged)
        exportCheck.toolTip = "Export a video for every file. Off: only analyse and build the camera path (keyframes are saved next to each video)."
        qualityPopup = Kit.popup(AnalysisQuality.allCases.map(\.rawValue), tip: AnalysisQuality.popupTip, target: self, action: #selector(optionsChanged))
        stylePopup = Kit.popup(PathStyle.allCases.map(\.rawValue), tip: "Camera path style used when a path is built", target: self, action: #selector(optionsChanged))
        folderButton.title = "Choose…"
        folderButton.bezelStyle = .rounded
        folderButton.target = self; folderButton.action = #selector(chooseFolder)
        folderButton.toolTip = "Folder for the exported videos (never the footage folder by default). Sidecar files are still written next to each source file."
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let folderRow = NSStackView(views: [folderButton, folderLabel])
        folderRow.spacing = 8
        folderRow.distribution = .fill
        folderLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        folderButton.setContentHuggingPriority(.required, for: .horizontal)
        settingsView.onChange = { [weak self] in self?.runner.settings.exportSettings = $0 }
        settingsView.identifier = Kit.fullWidthID
        let right = Kit.pageStack([
            Kit.title("Batch", tip: "Applies to every file in the list. Cuts, captions, location cards and global fov come from each file's own project; the export settings below replace its export settings."),
            Kit.grid([
                Kit.checkRow(forceCheck),
                Kit.checkRow(exportCheck),
                Kit.row("Quality", qualityPopup, tip: AnalysisQuality.popupTip),
                Kit.row("Path style", stylePopup, tip: "Camera path style"),
                Kit.row("Output", folderRow, tip: "Output folder for the exported videos"),
            ]),
            Kit.title("Export settings", tip: "Used for every exported file in this batch (stored separately from the per-video export settings)."),
            settingsView,
        ])
        right.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let top = NSStackView(views: [left, right])
        top.orientation = .horizontal
        top.alignment = .top
        top.spacing = 12
        let root = NSStackView(views: [top, bottom])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            top.widthAnchor.constraint(equalTo: root.widthAnchor),
            bottom.widthAnchor.constraint(equalTo: root.widthAnchor),
            left.heightAnchor.constraint(equalTo: top.heightAnchor),
            right.heightAnchor.constraint(equalTo: top.heightAnchor),
        ])
    }

    // MARK: State

    private func refresh() {
        let q = runner.queue, s = runner.settings
        let selection = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selection.filteredIndexSet { $0 < q.items.count }, byExtendingSelection: false)

        forceCheck.state = s.forceReanalyse ? .on : .off
        exportCheck.state = s.export ? .on : .off
        stylePopup.selectItem(at: PathStyle.allCases.firstIndex(of: s.style) ?? 0)
        qualityPopup.selectItem(at: AnalysisQuality.allCases.firstIndex(of: s.analysisQuality) ?? 0)
        folderButton.isEnabled = s.export
        folderLabel.stringValue = s.outputFolder?.path ?? (s.export ? "Not chosen" : "")
        folderLabel.textColor = s.export && s.outputFolder == nil ? .systemRed : .labelColor
        settingsView.settings = s.exportSettings
        settingsView.alphaValue = s.export ? 1 : 0.5

        switch q.runState {
        case .running: startButton.title = "Pause"
        case .pausing: startButton.title = "Pausing…"
        case .paused: startButton.title = "Resume"
        case .idle: startButton.title = "Start"
        }
        startButton.toolTip = q.runState == .running ? "Finish the current file, then stop" : "Process the files in the list from the top"
        startButton.isEnabled = !q.items.isEmpty && (q.isRunning || q.hasPending || q.hasFailed)
        removeButton.isEnabled = !table.selectedRowIndexes.isEmpty
        clearButton.isEnabled = !q.items.isEmpty
        clearDoneButton.isEnabled = q.items.contains { $0.state == .done }

        progress.doubleValue = runner.progress
        let done = q.items.filter { $0.state == .done }.count
        let failed = q.items.filter { if case .failed = $0.state { return true } else { return false } }.count
        summary.stringValue = q.items.isEmpty ? "" : "\(done) of \(q.items.count) done" + (failed > 0 ? ", \(failed) failed" : "")
    }

    // MARK: Actions

    @objc private func startPause() {
        switch runner.queue.runState {
        case .running: runner.pause()
        default:
            if let problem = runner.start() {
                let alert = NSAlert()
                alert.messageText = problem
                alert.beginSheetModal(for: window!)
            }
        }
        refresh()
    }

    @objc private func optionsChanged() {
        runner.settings.forceReanalyse = forceCheck.state == .on
        runner.settings.export = exportCheck.state == .on
        runner.settings.analysisQuality = AnalysisQuality.allCases[max(qualityPopup.indexOfSelectedItem, 0)]
        runner.settings.style = PathStyle.allCases[max(stylePopup.indexOfSelectedItem, 0)]
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Folder for the exported videos"
        if let cur = runner.settings.outputFolder { panel.directoryURL = cur }
        if panel.runModal() == .OK, let url = panel.url { runner.settings.outputFolder = url }
    }

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .data, .folder]
        panel.message = "Choose .360 files or folders"
        if panel.runModal() == .OK { runner.add(panel.urls) }
    }

    @objc private func removeSelectedAction() { removeSelected() }

    private func removeSelected() {
        let items = runner.queue.items
        runner.remove(Set(table.selectedRowIndexes.compactMap { items.indices.contains($0) ? items[$0].id : nil }))
    }

    @objc private func clearFinished() { runner.removeFinished() }

    @objc private func clearAll() {
        let q = runner.queue
        guard q.items.count > 1 || !q.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = "Clear the list?"
        alert.informativeText = "All \(q.items.count) files are removed from the list. The files themselves are not touched."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] r in if r == .alertFirstButtonReturn { self?.runner.clear() } }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { removeButton.isEnabled = !table.selectedRowIndexes.isEmpty }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { runner.queue.items.count }

    static func statusText(_ state: BatchItem.State) -> String {
        switch state {
        case .pending: return "Waiting"
        case .analysing(let p): return "Analysing \(Int(p * 100))%"
        case .building: return "Building path"
        case .exporting(let p): return "Exporting \(Int(p * 100))%"
        case .done: return "Done"
        case .failed(let m): return "Failed: \(m)"
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let items = runner.queue.items
        guard items.indices.contains(row), let col = tableColumn else { return nil }
        let item = items[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if col.identifier.rawValue == "name" {
            text.stringValue = item.url.lastPathComponent
            text.toolTip = item.url.path
        } else {
            text.stringValue = Self.statusText(item.state)
            text.toolTip = item.output.map { "Output: " + $0.path } ?? text.stringValue
            if case .failed = item.state { text.textColor = .systemRed }
            else if item.state == .done { text.textColor = .systemGreen }
            else if item.state == .pending { text.textColor = .secondaryLabelColor }
        }
        return cell
    }

    // Drag: rows to reorder, files and folders from Finder to add.

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        if info.draggingSource as? NSTableView === tableView { return .move }
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if info.draggingSource as? NSTableView === tableView {
            let rows = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: rowType).flatMap(Int.init) }
            guard !rows.isEmpty else { return false }
            runner.move(from: IndexSet(rows), to: row)
            return true
        }
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        runner.add(urls)
        return true
    }

    func windowWillClose(_ notification: Notification) {}
}
