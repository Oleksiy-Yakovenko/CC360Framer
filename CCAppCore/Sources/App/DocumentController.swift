import AppKit
import os

/// The shared document controller: File > Open, Open Recent, dedupe of files that are open already and the list of open
/// files that is reopened at the next launch (the way PCBDesigner remembers its open projects).
@MainActor
final class DocumentController: NSDocumentController {
    /// The open files, persisted; nil for dev and headless runs, which neither restore nor change the saved session.
    private(set) var store: OpenDocumentsStore?
    private var pendingRestore: [URL] = []
    /// Closing the documents while the app quits must not make them forgotten.
    private(set) var isTerminating = false
    /// Called after a document has been added (the welcome window closes then).
    var onDocumentAdded: (() -> Void)?

    init(persistsSession: Bool) {
        super.init()
        if persistsSession {
            let store = OpenDocumentsStore()
            self.store = store
            pendingRestore = store.restorable()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func willTerminate() {
        isTerminating = true
        PersistenceLog.logger.info("Terminating: \(self.recentDocumentURLs.count) in the system's recent documents")
    }

    /// Reopens the files of the previous session (once), skipping missing ones; failures are forgotten.
    func restoreSession() {
        let urls = pendingRestore
        pendingRestore = []
        open(urls, quietFailure: true)
    }

    /// Opens the files, each in a window of its own; one that is open already is brought forward.
    func open(_ urls: [URL], quietFailure: Bool = false) {
        for url in urls {
            openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                guard let error else { return }
                MainActor.assumeIsolated {
                    self?.store?.remove(url)
                    if !quietFailure { NSApp.presentError(error) }
                }
            }
        }
    }

    override func addDocument(_ document: NSDocument) {
        super.addDocument(document)
        if let url = document.fileURL {
            store?.add(url)
            // AppKit records it when a document is opened through openDocument(withContentsOf:), not when one is only added.
            noteNewRecentDocumentURL(url)
            PersistenceLog.logger.info("Recent: added \(url.path, privacy: .public); \(self.recentDocumentURLs.count) in the system's recent documents")
        }
        onDocumentAdded?()
    }

    /// What is remembered at launch, to find out when it is lost (Console.app, category "Persistence", or the Xcode console).
    func logPersistedState() {
        let open = OpenDocumentsStore().paths.count
        PersistenceLog.logger.info("Launch: \(self.recentDocumentURLs.count) in the system's recent documents, \(open) open document(s) remembered, bundle \(Bundle.main.bundleIdentifier ?? "none", privacy: .public)")
    }

    override func removeDocument(_ document: NSDocument) {
        super.removeDocument(document)
        if !isTerminating, let url = document.fileURL { store?.remove(url) }
    }

    // MARK: Document types
    // The `.360` type is only known to Launch Services once the bundle is registered, and not at all when running the bare
    // binary, so every file is treated as a 360 video; the model reports what it cannot play.

    override func typeForContents(of url: URL) throws -> String { VideoDocument.typeName }
    override var defaultType: String? { VideoDocument.typeName }
    override func documentClass(forType typeName: String) -> AnyClass? { VideoDocument.self }

    /// Any file can be chosen (`.360` has no system type unless the bundle declares one).
    override func runModalOpenPanel(_ openPanel: NSOpenPanel, forTypes types: [String]?) -> Int {
        super.runModalOpenPanel(openPanel, forTypes: nil)
    }
}

/// What is remembered between launches, and when it is read, written or dropped.
/// Shown in the Xcode console, and in Console.app under the category "Persistence".
enum PersistenceLog {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "CC360Framer", category: "Persistence")
}
