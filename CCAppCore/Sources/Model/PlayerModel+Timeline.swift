import AVFoundation
import Combine
import AppKit

/// Cut regions and the generic timeline adapters (keyframes, cuts) that drive the bottom bar and the seekbar markers.
extension PlayerModel {
    /// Called when cuts or the preview checkbox change: persist and refresh the preview skipping.
    func cutsChanged() {
        guard !loadingProjectFlag else { return }
        saveProject()
        updateCutPreview()
    }

    var selectedCutRegion: CutRegion? { selectedCut.flatMap { id in cuts.first { $0.id == id } } }

    /// Adds a cut of the default length at the playhead (clamped, never overlapping another cut).
    func addCut() {
        guard duration > 0 else { return }
        guard let r = RegionEdit.add(cuts, at: position, duration: duration, make: { CutRegion(start: $0, end: $1) }) else {
            statusText = "No room for a cut here: the playhead is inside a cut or too close to the next one."
            return
        }
        cutUndo.perform("Add Cut") {
            cuts = r.regions
            selectedCut = r.added.id
        }
    }

    func deleteSelectedCut() {
        guard let id = selectedCut else { return }
        cutUndo.perform("Delete Cut") {
            cuts.removeAll { $0.id == id }
            selectedCut = nil
        }
    }

    func clearCuts() {
        guard !cuts.isEmpty else { return }
        cutUndo.perform("Clear Cuts") {
            cuts = []
            selectedCut = nil
        }
    }

    /// Selects a cut and puts the playhead at its start.
    func selectCut(_ id: UUID, seek: Bool = true) {
        selectedCut = id
        guard seek, let r = cuts.first(where: { $0.id == id }) else { return }
        position = r.start
        scrub(to: r.start)
        endScrub(at: r.start)
    }

    /// Inspector edit of the selected cut's times (rejected values leave the cut as it was).
    func editSelectedCut(start: Double, end: Double) {
        guard let id = selectedCut else { return }
        guard let new = RegionEdit.setRange(cuts, id: id, start: start, end: end, duration: duration) else {
            objectWillChange.send()   // let the fields snap back
            return
        }
        guard new != cuts else { return }
        cutUndo.perform("Edit Cut") { cuts = new }
    }

    /// Dragging a handle: one undo step for the whole drag.
    func beginCutDrag() { cutDragStart = CutSnapshot(cuts: cuts, selected: selectedCut) }

    func dragCut(_ id: UUID, edge: RegionEdit.Edge, to time: Double) {
        cuts = RegionEdit.moveEdge(cuts, id: id, edge: edge, to: time, duration: duration)
    }

    func endCutDrag() {
        defer { cutDragStart = nil }
        guard let before = cutDragStart, before.cuts != cuts else { return }
        cutUndo.register(before, "Resize Cut")
    }

    /// Time map for export and preview (`crossfade` is 0 for the preview).
    func timeMap(crossfade: Double) -> TimeMap { TimeMap(cuts: cuts, duration: duration, crossfade: crossfade) }

    /// The adapter for a timeline kind.
    func timeline(_ kind: TimelineKind) -> TimelineAdapter {
        switch kind {
        case .keyframes: return KeyframeTimeline(model: self)
        case .cuts: return CutTimeline(model: self)
        case .locationCards: return LocationCardTimeline(model: self)
        case .captions: return CaptionTimeline(model: self)
        case .audio: return AudioClipTimeline(model: self)
        }
    }

    var timeline: TimelineAdapter { timeline(activeTimeline) }
}

/// What the bottom bar and the seekbar markers need from a timeline.
@MainActor
protocol TimelineAdapter {
    var kind: TimelineKind { get }
    var items: [TimelineItem] { get }
    var selected: UUID? { get }
    var addTitle: String { get }
    var deleteTitle: String { get }
    var clearTitle: String { get }
    var addTip: String { get }
    var deleteTip: String { get }
    var clearTip: String { get }
    var canAdd: Bool { get }
    var canDelete: Bool { get }
    var canClear: Bool { get }
    /// Confirmation texts (message, informative text) shown before delete and clear.
    var deleteConfirm: (String, String) { get }
    var clearConfirm: (String, String) { get }
    func select(_ id: UUID)
    /// Selects without moving the playhead (start of a handle drag).
    func selectQuietly(_ id: UUID)
    func add()
    func deleteSelected()
    func clear()
    func beginDrag()
    func drag(_ id: UUID, edge: RegionEdit.Edge, to time: Double)
    func endDrag()
}

extension TimelineAdapter {
    func selectQuietly(_ id: UUID) { select(id) }
    func beginDrag() {}
    func drag(_ id: UUID, edge: RegionEdit.Edge, to time: Double) {}
    func endDrag() {}
}

@MainActor
struct KeyframeTimeline: TimelineAdapter {
    let model: PlayerModel
    var kind: TimelineKind { .keyframes }
    var items: [TimelineItem] { model.keyframes.map { TimelineItem(id: $0.id, start: $0.time, end: nil) } }
    var selected: UUID? { model.selectedKey }
    var addTitle: String { "Set key" }
    var deleteTitle: String { "Delete key" }
    var clearTitle: String { "Clear keys" }
    var addTip: String { "Keyframe the current view at the playhead (K)" }
    var deleteTip: String { "Delete the selected keyframe (Delete)" }
    var clearTip: String { "Remove all keyframes" }
    var canAdd: Bool { model.duration > 0 }
    var canDelete: Bool { model.selectedKey != nil }
    var canClear: Bool { !model.keyframes.isEmpty }
    var deleteConfirm: (String, String) { ("Delete the selected keyframe?", "You can undo it with Edit > Undo.") }
    var clearConfirm: (String, String) { ("Clear all keyframes?", "This removes every keyframe. You can undo it with Edit > Undo.") }
    func select(_ id: UUID) { if let k = model.keyframes.first(where: { $0.id == id }) { model.select(k) } }
    func add() { model.setKey() }
    func deleteSelected() { model.deleteSelectedKey() }
    func clear() { model.clearKeys() }
}

@MainActor
struct CutTimeline: TimelineAdapter {
    let model: PlayerModel
    var kind: TimelineKind { .cuts }
    var items: [TimelineItem] { model.cuts.map { TimelineItem(id: $0.id, start: $0.start, end: $0.end) } }
    var selected: UUID? { model.selectedCut }
    var addTitle: String { "Add cut" }
    var deleteTitle: String { "Delete cut" }
    var clearTitle: String { "Clear cuts" }
    var addTip: String { "Add a cut of 3 s at the playhead; drag its handles on the seekbar to resize" }
    var deleteTip: String { "Delete the selected cut (Delete)" }
    var clearTip: String { "Remove all cuts" }
    var canAdd: Bool { model.duration > 0 }
    var canDelete: Bool { model.selectedCut != nil }
    var canClear: Bool { !model.cuts.isEmpty }
    var deleteConfirm: (String, String) { ("Delete the selected cut?", "The footage is kept again. You can undo it with Edit > Undo.") }
    var clearConfirm: (String, String) { ("Clear all cuts?", "All cut regions are removed. You can undo it with Edit > Undo.") }
    func select(_ id: UUID) { model.selectCut(id) }
    func selectQuietly(_ id: UUID) { model.selectCut(id, seek: false) }
    func add() { model.addCut() }
    func deleteSelected() { model.deleteSelectedCut() }
    func clear() { model.clearCuts() }
    func beginDrag() { model.beginCutDrag() }
    func drag(_ id: UUID, edge: RegionEdit.Edge, to time: Double) { model.dragCut(id, edge: edge, to: time) }
    func endDrag() { model.endCutDrag() }
}

extension PlayerModel {
    /// Preview with cuts applied: playback skips the cut regions, dissolving over the export's crossfade (second player,
    /// see `PlayerModel+Dissolve`); cuts without a dissolve (crossfade 0, tiny segments, the end of the clip) are hard
    /// jumps by boundary observer + seek. The seekbar keeps showing the source timeline and scrubbing into a cut is still
    /// possible. Rebuilt whenever the cuts, the checkbox or the crossfade change.
    func updateCutPreview() {
        if let cutObserver { cutObserverPlayer?.removeTimeObserver(cutObserver) }
        cutObserver = nil; cutObserverPlayer = nil
        configureDissolve()
        guard previewWithCuts, player.currentItem != nil else { return }
        let map = timeMap(crossfade: previewCrossfade)
        let points = map.hardJumps
        guard !points.isEmpty else { return }
        let times = points.map { NSValue(time: CMTime(seconds: $0.from, preferredTimescale: 600)) }
        cutObserverPlayer = player
        cutObserver = player.addBoundaryTimeObserver(forTimes: times, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.skipCutIfNeeded() }
        }
        skipCutIfNeeded()
    }

    /// Moves the playhead out of a cut while playing with cuts applied (stops at the end of the clip).
    func skipCutIfNeeded() {
        guard previewWithCuts, isPlaying else { return }
        let now = player.currentTime().seconds
        let map = timeMap(crossfade: 0)
        let target = map.skipTarget(forSource: now + 0.02)
        guard target > now + 0.02 else { return }
        if target >= duration - 0.02 {
            player.pause()
            isPlaying = false
            scrub(to: duration); endScrub(at: duration)
        } else {
            scrub(to: target); endScrub(at: target)
        }
    }
}
