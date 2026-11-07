import Combine
import Foundation

/// Captions: editing (undoable), the global caption style and the timeline adapter.
extension PlayerModel {
    func captionsChanged() {
        guard !loadingProjectFlag else { return }
        rebuildOverlays()
        saveProject()
    }

    var selectedCaptionValue: Caption? { selectedCaption.flatMap { id in captions.first { $0.id == id } } }

    /// Adds a caption of the default length at the playhead (clamped, never overlapping another caption).
    func addCaption() {
        guard duration > 0 else { return }
        guard let r = RegionEdit.add(captions, at: position, duration: duration, make: { Caption(start: $0, end: $1) }) else {
            statusText = "No room for a caption here: the playhead is inside a caption or too close to the next one."
            return
        }
        captionUndo.perform("Add Caption") {
            captions = r.regions
            selectedCaption = r.added.id
        }
    }

    func deleteSelectedCaption() {
        guard let id = selectedCaption else { return }
        captionUndo.perform("Delete Caption") {
            captions.removeAll { $0.id == id }
            selectedCaption = nil
        }
    }

    func clearCaptions() {
        guard !captions.isEmpty else { return }
        captionUndo.perform("Clear Captions") {
            captions = []
            selectedCaption = nil
        }
    }

    func selectCaption(_ id: UUID, seek: Bool = true) {
        selectedCaption = id
        guard seek, let c = captions.first(where: { $0.id == id }) else { return }
        position = c.start
        scrub(to: c.start)
        endScrub(at: c.start)
    }

    /// Inspector edit of the selected caption's times (rejected values leave it as it was).
    func editSelectedCaption(start: Double, end: Double) {
        guard let id = selectedCaption else { return }
        guard let new = RegionEdit.setRange(captions, id: id, start: start, end: end, duration: duration) else {
            objectWillChange.send()
            return
        }
        guard new != captions else { return }
        captionUndo.perform("Edit Caption") { captions = new }
    }

    /// Changes text or overrides of the selected caption (undoable; repeated edits with the same `name` within a second
    /// collapse into one undo step, e.g. while typing or dragging a colour).
    func editSelectedCaption(name: String, _ change: (inout Caption) -> Void) {
        guard let id = selectedCaption, let i = captions.firstIndex(where: { $0.id == id }) else { return }
        var new = captions
        change(&new[i])
        if new[i].overrides?.isEmpty == true { new[i].overrides = nil }
        guard new != captions else { return }
        let before = CaptionSnapshot(captions: captions, selected: selectedCaption)
        captions = new
        let now = Date()
        if let last = lastCaptionEdit, last.name == name, now.timeIntervalSince(last.at) < 1 { lastCaptionEdit = (name, now); return }
        lastCaptionEdit = (name, now)
        captionUndo.register(before, name)
    }

    func beginCaptionDrag() { captionDragStart = CaptionSnapshot(captions: captions, selected: selectedCaption) }

    func dragCaption(_ id: UUID, edge: RegionEdit.Edge, to time: Double) {
        captions = RegionEdit.moveEdge(captions, id: id, edge: edge, to: time, duration: duration)
    }

    func dragCaption(_ id: UUID, toStart start: Double) {
        captions = RegionEdit.move(captions, id: id, toStart: start, duration: duration)
    }

    func endCaptionDrag(name: String = "Resize Caption") {
        defer { captionDragStart = nil }
        guard let before = captionDragStart, before.captions != captions else { return }
        captionUndo.register(before, name)
    }

    // MARK: Global style

    /// Stores a style without registering undo (also the undo/redo restore path).
    func applyCaptionStyle(_ s: CaptionStyle) {
        captionStyle = s
        s.saveDefaults()
        rebuildOverlays()
        saveProject()
    }

    /// Changes the global caption style (undoable, saved per file and as the app default; edits of one control within 1 s coalesce).
    func setCaptionStyle(_ new: CaptionStyle, name: String = "Change Caption Style") {
        guard new != captionStyle else { return }
        let before = captionStyle
        applyCaptionStyle(new)
        let now = Date()
        if let last = lastCaptionStyleEdit, last.name == name, now.timeIntervalSince(last.at) < 1 { lastCaptionStyleEdit = (name, now); return }
        lastCaptionStyleEdit = (name, now)
        captionStyleUndo.register(before, name)
    }
}

@MainActor
struct CaptionTimeline: TimelineAdapter {
    let model: PlayerModel
    var kind: TimelineKind { .captions }
    var items: [TimelineItem] { model.captions.map { TimelineItem(id: $0.id, start: $0.start, end: $0.end) } }
    var selected: UUID? { model.selectedCaption }
    var addTitle: String { "Add caption" }
    var deleteTitle: String { "Delete caption" }
    var clearTitle: String { "Clear captions" }
    var addTip: String { "Add a caption of 3 s at the playhead; drag its handles on the seekbar to resize, edit the text in the Inspector tab" }
    var deleteTip: String { "Delete the selected caption (Delete)" }
    var clearTip: String { "Remove all captions" }
    var canAdd: Bool { model.duration > 0 }
    var canDelete: Bool { model.selectedCaption != nil }
    var canClear: Bool { !model.captions.isEmpty }
    var deleteConfirm: (String, String) { ("Delete the selected caption?", "You can undo it with Edit > Undo.") }
    var clearConfirm: (String, String) { ("Clear all captions?", "All captions are removed. You can undo it with Edit > Undo.") }
    func select(_ id: UUID) { model.selectCaption(id) }
    func selectQuietly(_ id: UUID) { model.selectCaption(id, seek: false) }
    func add() { model.addCaption() }
    func deleteSelected() { model.deleteSelectedCaption() }
    func clear() { model.clearCaptions() }
    func beginDrag() { model.beginCaptionDrag() }
    func drag(_ id: UUID, edge: RegionEdit.Edge, to time: Double) { model.dragCaption(id, edge: edge, to: time) }
    func dragRegion(_ id: UUID, to start: Double) { model.dragCaption(id, toStart: start) }
    func endMove() { model.endCaptionDrag(name: "Move Caption") }
    func endDrag() { model.endCaptionDrag() }
}
