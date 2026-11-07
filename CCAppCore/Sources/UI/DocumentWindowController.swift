import AppKit

/// The window of one `VideoDocument`: the three-pane layout with the document's own `PlayerModel`. Its frame and the
/// divider positions are remembered per file.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let model: PlayerModel
    let main: MainViewController
    private let url: URL?
    private let layoutStore = SplitLayoutStore()
    private var layout = SplitLayout.standard
    private var pendingSave: DispatchWorkItem?

    init(model: PlayerModel, url: URL?, cascadeFrom ref: NSWindow?) {
        let main = MainViewController(model: model)
        self.model = model
        self.main = main
        self.url = url
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        shouldCascadeWindows = false
        window.isReleasedWhenClosed = false
        // The open documents are reopened by `DocumentController`, not by AppKit's window restoration (which would open them twice).
        window.isRestorable = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentMinSize = NSSize(width: 900, height: 520)
        window.title = url?.lastPathComponent ?? "CC360Framer"
        window.titleVisibility = .hidden
        if let url {
            let name = DocumentKeys.frameName(for: url)
            if !window.setFrameUsingName(name) { place(window, cascadeFrom: ref) }
            window.setFrameAutosaveName(name)
            layout = layoutStore.load(for: url) ?? .standard
        } else {
            place(window, cascadeFrom: ref)
        }
        main.install(in: window, layout: layout)
        main.onLayoutChange = { [weak self] in self?.layoutChanged() }
        main.openURLs = { urls in (NSDocumentController.shared as? DocumentController)?.open(urls) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func place(_ window: NSWindow, cascadeFrom ref: NSWindow?) {
        if let ref {
            window.setFrame(ref.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: ref.frame.minX, y: ref.frame.maxY)))
        } else {
            window.center()
        }
    }

    func open(_ url: URL) {
        Task { await model.open(url) }
    }

    /// Divider moves are saved a moment after the last one.
    private func layoutChanged() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveState() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Saves the pane widths and the window frame now.
    func saveState() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let url, let window else { return }
        layout = main.currentLayout(base: layout)
        layoutStore.save(layout, for: url)
        window.saveFrame(usingName: DocumentKeys.frameName(for: url))
    }

    func windowWillClose(_ notification: Notification) {
        saveState()
        // Releases the name, so the same file can use it again when it is reopened before this window is deallocated.
        window?.setFrameAutosaveName("")
    }
}
