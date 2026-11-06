import AppKit

/// A `.360` file opened in the app: a read-only viewer-type document. It owns the `PlayerModel` of its window; edits
/// (keyframes, cuts, captions, settings) are written to the sidecar files by the model, so the document is never "edited"
/// and closing it never asks to save.
@objc(CC360VideoDocument)
@MainActor
final class VideoDocument: NSDocument {
    /// Type name declared in `Info.plist` (`UTImportedTypeDeclarations`, see `build.sh`).
    nonisolated static let typeName = "dev.cc360framer.gopro-360"

    let model = PlayerModel()

    nonisolated override class var autosavesInPlace: Bool { false }
    nonisolated override class var readableTypes: [String] { [typeName] }
    nonisolated override class var writableTypes: [String] { [] }

    /// The model registers its undo steps on this document's own (default NSDocument) undo manager, so the window, the
    /// Edit menu and text views share it. NSDocument's change counting stays unused: the sidecars persist the edits.
    override init() {
        super.init()
        model.undoManagerProvider = { [weak self] in self?.undoManager }
    }

    /// Nothing is read here: the media is loaded asynchronously by the model once the window exists. Only an unreadable
    /// file is refused up front.
    override func read(from url: URL, ofType typeName: String) throws {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: [NSURLErrorKey: url])
        }
    }

    override func makeWindowControllers() {
        let others = NSDocumentController.shared.documents.filter { $0 !== self }.compactMap { $0.windowControllers.first?.window }
        let controller = DocumentWindowController(model: model, url: fileURL, cascadeFrom: others.last)
        addWindowController(controller)
        if let url = fileURL { controller.open(url) }
    }

    var documentWindowController: DocumentWindowController? { windowControllers.first as? DocumentWindowController }

    override func close() {
        model.cancelJob()
        model.cleanup()
        super.close()
    }
}
