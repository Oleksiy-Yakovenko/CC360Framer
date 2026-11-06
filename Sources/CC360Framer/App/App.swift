import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = PlayerModel()
    private var window: NSWindow!
    private var main: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        main = MainViewController(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = main
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentMinSize = NSSize(width: 900, height: 520)
        window.title = "CC360Framer"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.toolbar = main.makeToolbar()
        if !window.setFrameUsingName("MainWindow") { window.center() }
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // First non-flag argument is a file to open on launch.
        if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            Task { await model.open(URL(fileURLWithPath: path)) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model.cleanup() }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { Task { await model.open(url) } }
    }

    // MARK: Actions (menu and toolbar)

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "360") ?? .movie, .movie, .mpeg4Movie]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.open(url) }
        }
    }

    @objc func exportDocument(_ sender: Any?) {
        if model.exportProgress != nil { model.cancelJob(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (model.title as NSString).deletingPathExtension + "-reframed.mp4"
        if panel.runModal() == .OK, let url = panel.url { model.export(preset: model.exportPreset, to: url) }
    }

    @objc func toggleSidebar(_ sender: Any?) { main.toggleSidebar(sender) }
    @objc func toggleInspector(_ sender: Any?) { main.toggleInspector() }
    @objc func togglePlay(_ sender: Any?) { model.togglePlay() }
    @objc func setKey(_ sender: Any?) { model.setKey() }
    @objc func deleteKey(_ sender: Any?) { model.deleteSelectedKey() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(exportDocument): return model.duration > 0 || model.exportProgress != nil
        case #selector(deleteKey): return model.selectedKey != nil
        case #selector(togglePlay), #selector(setKey): return model.duration > 0
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
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")

        let view = submenu("View")
        add(view, "Toggle Left Sidebar", #selector(toggleSidebar), "s", [.command, .control], target: self)
        add(view, "Toggle Right Sidebar", #selector(toggleInspector), "2", [.command, .option], target: self)

        let play = submenu("Playback")
        add(play, "Play / Pause", #selector(togglePlay), " ", [], target: self)
        add(play, "Set Keyframe", #selector(setKey), "k", [], target: self)
        add(play, "Delete Keyframe", #selector(deleteKey), "\u{8}", [], target: self)

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
