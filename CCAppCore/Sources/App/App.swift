import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private let documents: DocumentController
    private let launchFile: URL?
    private lazy var batchWindow = BatchWindowController()
    /// There is only one welcome window at a time.
    private var welcomeWindow: WelcomeWindowController?

    init(documents: DocumentController, launchFile: URL?) {
        self.documents = documents
        self.launchFile = launchFile
        super.init()
    }

    /// The document menu actions apply to: the key window's, else the main window's, else the newest.
    private var current: VideoDocument? {
        (NSApp.keyWindow?.windowController?.document as? VideoDocument)
            ?? (documents.currentDocument as? VideoDocument)
            ?? (documents.documents.last as? VideoDocument)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        documents.onDocumentAdded = { [weak self] in self?.welcomeWindow?.close() }
        // Before AppKit decides whether anything was opened (and the untitled-file hook below runs).
        if let launchFile {
            documents.open([launchFile])
        } else {
            documents.restoreSession()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the last window keeps the app (and a running batch) alive; files open from the menu.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        documents.willTerminate()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        for case let doc as VideoDocument in documents.documents {
            doc.documentWindowController?.saveState()
            doc.model.flushPendingSaves()
            doc.model.cleanup()
        }
    }

    /// Instead of an untitled document, the welcome window is shown at launch and when the app is activated without windows
    /// (unless a file got opened, or is being reopened from the last session).
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if documents.documents.isEmpty { showWelcome(nil) }
        return true
    }

    @objc func showWelcome(_ sender: Any?) {
        if welcomeWindow == nil {
            welcomeWindow = WelcomeWindowController(
                recents: { [documents] in documents.recentDocumentURLs },
                open: { [documents] in documents.open([$0]) },
                openOther: { [documents] in documents.openDocument(nil) })
        }
        welcomeWindow?.showWindow(nil)
        welcomeWindow?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let entries = RecentDocumentEntry.entries(from: documents.recentDocumentURLs)
        for (entry, title) in zip(entries, RecentDocumentEntry.menuTitles(entries)) {
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
            menu.addItem(item)
        }
        if entries.isEmpty {
            let none = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = documents
        clear.isEnabled = !entries.isEmpty
        menu.addItem(clear)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { documents.open([url]) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Actions (menu and toolbar)

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
    @objc func toggleSidebar(_ sender: Any?) { current?.documentWindowController?.main.toggleSidebar(sender) }
    @objc func toggleInspector(_ sender: Any?) { current?.documentWindowController?.main.toggleInspector() }
    @objc func togglePlay(_ sender: Any?) { current?.model.togglePlay() }
    @objc func setKey(_ sender: Any?) { current?.model.setKey() }
    @objc func deleteKey(_ sender: Any?) { current?.documentWindowController?.main.center.timelineBar.confirmDelete() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Unmodified Space / K / Delete must reach a text field being edited instead.
        let typing = NSApp.keyWindow?.firstResponder.map(TextEditing.isEditing) ?? false
        let model = current?.model
        switch item.action {
        case #selector(deleteKey): return !typing && model?.timeline.canDelete == true
        case #selector(togglePlay), #selector(setKey): return !typing && (model?.duration ?? 0) > 0
        case #selector(exportDocument):
            item.title = model?.exportProgress != nil ? "Cancel Export" : "Export…"
            return (model?.duration ?? 0) > 0 || model?.exportProgress != nil
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
        // Marking the submenu as NSApp.servicesMenu makes AppKit fill it with the system services.
        let servicesMenu = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        app.addItem(.separator())
        add(app, "Hide CC360Framer", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Quit CC360Framer", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = submenu("File")
        add(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o", target: documents)
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        // A menu built in code is not AppKit's recent-documents menu (a XIB marks it with systemMenu="recentDocuments"), so it
        // is filled from the document controller's recent URLs whenever it opens.
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recent.submenu = recentMenu
        file.addItem(recent)
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")

        let edit = submenu("Edit")
        add(edit, "Undo", Selector(("undo:")), "z")
        add(edit, "Redo", Selector(("redo:")), "z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Delete", #selector(NSText.delete(_:)), "", [])
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        // The standard text submenus act on the first responder (the Inspector's text fields); no target.
        edit.addItem(.separator())
        func textSubmenu(_ title: String, _ items: [(String, String, String, NSEvent.ModifierFlags)?]) {
            let m = NSMenu(title: title)
            edit.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = m
            for item in items {
                guard let (t, a, key, mods) = item else { m.addItem(.separator()); continue }
                add(m, t, NSSelectorFromString(a), key, mods)
            }
        }
        textSubmenu("Spelling and Grammar", [
            ("Show Spelling and Grammar", "showGuessPanel:", ":", .command),
            ("Check Document Now", "checkSpelling:", ";", .command), nil,
            ("Check Spelling While Typing", "toggleContinuousSpellChecking:", "", .command),
            ("Check Grammar With Spelling", "toggleGrammarChecking:", "", .command),
            ("Correct Spelling Automatically", "toggleAutomaticSpellingCorrection:", "", .command)])
        textSubmenu("Substitutions", [
            ("Show Substitutions", "orderFrontSubstitutionsPanel:", "", .command), nil,
            ("Smart Copy/Paste", "toggleSmartInsertDelete:", "", .command),
            ("Smart Quotes", "toggleAutomaticQuoteSubstitution:", "", .command),
            ("Smart Dashes", "toggleAutomaticDashSubstitution:", "", .command),
            ("Smart Links", "toggleAutomaticLinkDetection:", "", .command),
            ("Data Detectors", "toggleAutomaticDataDetection:", "", .command),
            ("Text Replacement", "toggleAutomaticTextReplacement:", "", .command)])
        textSubmenu("Transformations", [
            ("Make Upper Case", "uppercaseWord:", "", .command),
            ("Make Lower Case", "lowercaseWord:", "", .command),
            ("Capitalize", "capitalizeWord:", "", .command)])
        textSubmenu("Speech", [
            ("Start Speaking", "startSpeaking:", "", .command),
            ("Stop Speaking", "stopSpeaking:", "", .command)])

        let view = submenu("View")
        add(view, "Toggle Left Sidebar", #selector(toggleSidebar), "s", [.command, .control], target: self)
        add(view, "Toggle Right Sidebar", #selector(toggleInspector), "2", [.command, .option], target: self)
        view.addItem(.separator())
        add(view, "Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let play = submenu("Playback")
        add(play, "Play / Pause", #selector(togglePlay), " ", [], target: self)
        add(play, "Set Keyframe", #selector(setKey), "k", [], target: self)
        add(play, "Delete Selected", #selector(deleteKey), "\u{8}", [], target: self)

        let actions = submenu("Actions")
        add(actions, "Export…", #selector(exportDocument), "e", target: self)

        let windows = submenu("Window")
        add(windows, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(windows, "Zoom", #selector(NSWindow.performZoom(_:)))
        windows.addItem(.separator())
        add(windows, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = windows
        let welcome = NSMenuItem(title: "Welcome to CC360Framer", action: #selector(showWelcome), keyEquivalent: "1")
        welcome.keyEquivalentModifierMask = [.command, .shift]
        welcome.target = self
        windows.insertItem(welcome, at: 0)
        windows.insertItem(.separator(), at: 1)
        windows.addItem(.separator())
        add(windows, "Batch Processing…", #selector(showBatch), "b", [.command, .shift], target: self)

        // An (empty) help menu: marking it as NSApp.helpMenu makes AppKit add the standard search field, which finds menu items.
        NSApp.helpMenu = submenu("Help")
        NSApp.mainMenu = bar
    }
}

enum CC360FramerApp {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let launchFile = launchFileArgument(CommandLine.arguments)
            // A file argument or CC360_DEBUG is a dev/headless run: it neither reopens nor changes the saved session.
            let persists = launchFile == nil && ProcessInfo.processInfo.environment["CC360_DEBUG"] == nil
            // Must exist before anything asks for the shared controller.
            let documents = DocumentController(persistsSession: persists)
            let delegate = AppDelegate(documents: documents, launchFile: launchFile)
            app.delegate = delegate
            app.run()
        }
    }
}
