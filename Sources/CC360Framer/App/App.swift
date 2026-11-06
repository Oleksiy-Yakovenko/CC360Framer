import AppKit
import UniformTypeIdentifiers

/// One window with its own `PlayerModel`: one per opened file.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let model: PlayerModel
    let main: MainViewController
    /// The file this window was asked to open (set before loading finishes, so it counts as taken immediately).
    private(set) var openedURL: URL?
    var isEmpty: Bool { openedURL == nil }
    var onClose: ((DocumentWindowController) -> Void)?

    init(autosave: Bool, cascadeFrom ref: NSWindow?) {
        let model = PlayerModel()
        let main = MainViewController(model: model)
        self.model = model
        self.main = main
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentMinSize = NSSize(width: 900, height: 520)
        window.title = "CC360Framer"
        window.titleVisibility = .hidden
        if autosave {
            if !window.setFrameUsingName("MainWindow") { window.center() }
            window.setFrameAutosaveName("MainWindow")
        } else if let ref {
            window.setFrame(ref.frame, display: false)
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: ref.frame.minX, y: ref.frame.maxY)))
        } else {
            window.center()
        }
        main.install(in: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func open(_ url: URL) {
        openedURL = url
        Task { await model.open(url) }
    }

    /// Edit > Undo/Redo and the text fields' field editor all use the model's undo manager.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }

    func windowWillClose(_ notification: Notification) {
        model.cancelJob()
        model.cleanup()
        onClose?(self)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controllers: [DocumentWindowController] = []
    private lazy var batchWindow = BatchWindowController()

    /// The window menu actions apply to: the key window's, else the main window's, else the newest.
    private var current: DocumentWindowController? {
        controllers.first { $0.window === NSApp.keyWindow } ?? controllers.first { $0.window === NSApp.mainWindow } ?? controllers.last
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let first = makeWindow()
        first.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        // First non-flag argument is a file to open on launch (CLI and headless modes use one file).
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            open(urls: [URL(fileURLWithPath: path)])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { controllers.forEach { $0.model.cleanup() } }

    func application(_ application: NSApplication, open urls: [URL]) { open(urls: urls) }

    private func makeWindow() -> DocumentWindowController {
        let c = DocumentWindowController(autosave: controllers.isEmpty, cascadeFrom: current?.window)
        c.onClose = { [weak self] closed in self?.controllers.removeAll { $0 === closed } }
        c.main.openURLs = { [weak self] urls in self?.open(urls: urls) }
        controllers.append(c)
        return c
    }

    /// One window per file: an empty window is reused first, a file that is already open is just brought forward.
    func open(urls: [URL]) {
        for url in urls {
            let std = url.standardizedFileURL
            if let existing = controllers.first(where: { $0.openedURL?.standardizedFileURL == std }) {
                existing.showWindow(nil)
                continue
            }
            let target = (current?.isEmpty == true ? current : nil) ?? controllers.first { $0.isEmpty } ?? makeWindow()
            target.open(url)
            target.showWindow(nil)
        }
    }

    // MARK: Actions (menu and toolbar)

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        // `.360` has no system type unless the app bundle declares one, so accept any file.
        panel.allowedContentTypes = [.movie, .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { open(urls: panel.urls) }
    }

    @objc func exportDocument(_ sender: Any?) {
        guard let model = current?.model else { return }
        if model.exportProgress != nil { model.cancelJob(); return }
        let panel = NSSavePanel()
        let container = model.exportSettings.container
        panel.allowedContentTypes = [container == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.nameFieldStringValue = (model.title as NSString).deletingPathExtension + "-reframed.\(container.fileExtension)"
        if panel.runModal() == .OK, let url = panel.url { model.export(to: url) }
    }

    @objc func showBatch(_ sender: Any?) { batchWindow.show() }
    @objc func toggleSidebar(_ sender: Any?) { current?.main.toggleSidebar(sender) }
    @objc func toggleInspector(_ sender: Any?) { current?.main.toggleInspector() }
    @objc func togglePlay(_ sender: Any?) { current?.model.togglePlay() }
    @objc func setKey(_ sender: Any?) { current?.model.setKey() }
    @objc func deleteKey(_ sender: Any?) { current?.main.center.timelineBar.confirmDelete() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Unmodified Space / K / Delete must reach a text field being edited instead.
        let typing = NSApp.keyWindow?.firstResponder is NSText
        let model = current?.model
        switch item.action {
        case #selector(deleteKey): return !typing && model?.timeline.canDelete == true
        case #selector(togglePlay), #selector(setKey): return !typing && (model?.duration ?? 0) > 0
        case #selector(exportDocument): return (model?.duration ?? 0) > 0 || model?.exportProgress != nil
        default: return true
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let bar = NSMenu()
        func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                 _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            item.target = target
        }
        func submenu(_ title: String) -> NSMenu {
            let m = NSMenu(title: title)
            bar.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
            return m
        }

        let app = submenu("CC360Framer")
        add(app, "About CC360Framer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Hide CC360Framer", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        app.addItem(.separator())
        add(app, "Quit CC360Framer", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = submenu("File")
        add(file, "Open…", #selector(openDocument), "o", target: self)
        add(file, "Export…", #selector(exportDocument), "e", target: self)
        add(file, "Batch Processing…", #selector(showBatch), "b", [.command, .shift], target: self)
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")

        let view = submenu("View")
        add(view, "Toggle Left Sidebar", #selector(toggleSidebar), "s", [.command, .control], target: self)
        add(view, "Toggle Right Sidebar", #selector(toggleInspector), "2", [.command, .option], target: self)

        let play = submenu("Playback")
        add(play, "Play / Pause", #selector(togglePlay), " ", [], target: self)
        add(play, "Set Keyframe", #selector(setKey), "k", [], target: self)
        add(play, "Delete Selected", #selector(deleteKey), "\u{8}", [], target: self)

        let windows = submenu("Window")
        add(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "Zoom", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = windows

        NSApp.mainMenu = bar
    }
}

enum CC360FramerApp {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }
}
