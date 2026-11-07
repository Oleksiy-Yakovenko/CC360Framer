import Combine
import Foundation

/// Audio clips (external music / voice-over): editing (undoable) and the timeline adapter. Clips may overlap, so the
/// editing goes through `AudioClipEdit`, not `RegionEdit`'s non-overlap rules.
extension PlayerModel {
    func audioClipsChanged() {
        guard !loadingProjectFlag else { return }
        let before = audioClips
        refreshAutoEnds()
        if audioClips != before { return }   // the nested change already saved and rebuilt
        saveProject()
        audioClipsAudioChanged()
    }

    /// Recomputes the ends of the auto clips from the probed file lengths (also starts the probes). Derived values: no
    /// undo step; if something changed, `audioClips` is set, which saves the project and rebuilds the preview.
    func refreshAutoEnds() {
        guard duration > 0, !loadingProjectFlag else { return }
        let new = AudioClipEdit.applyAutoEnds(audioClips, info: { c in
            guard let i = audioProbes.info(for: c.path), i.isUsable else { return nil }
            return i.duration
        }, videoDuration: duration)
        if new != audioClips { audioClips = new }
    }

    func audioProbesChanged() {
        refreshAutoEnds()
        objectWillChange.send()   // the Inspector shows the probe result
    }

    /// Inspector times of the selected clip. `end` nil = auto end (the clip follows its audio file; Start keeps working);
    /// a value sets the end explicitly. Rejected values leave the clip as it was.
    func editSelectedAudioClipTimes(start: Double, end: Double?) {
        guard let id = selectedAudioClip, let c = audioClips.first(where: { $0.id == id }) else { return }
        let e = end ?? min(duration, start + c.length)
        guard var new = AudioClipEdit.setRange(audioClips, id: id, start: start, end: e, duration: duration),
              let i = new.firstIndex(where: { $0.id == id }) else {
            objectWillChange.send()
            return
        }
        new[i].autoEnd = end == nil
        guard new != audioClips else { return }
        audioClipUndo.perform("Edit Audio Clip") { audioClips = new }
    }

    /// Called after the clips changed and the project was saved (export reads `audioClips` itself): rebuilds the
    /// preview item of the clip player (`AudioClipPlayback`: debounced, built off the main thread, keeps the position
    /// and play state).
    func audioClipsAudioChanged() {
        clipPlayback.setClips(audioClips, duration: duration)
    }

    var selectedAudioClipValue: AudioClip? { selectedAudioClip.flatMap { id in audioClips.first { $0.id == id } } }

    /// Adds a clip of the default length at the playhead (clamped into the video; may overlap other clips).
    func addAudioClip() {
        guard duration > 0 else { return }
        guard let r = AudioClipEdit.add(audioClips, at: position, duration: duration) else {
            statusText = "The video is too short for an audio clip."
            return
        }
        audioClipUndo.perform("Add Audio Clip") {
            audioClips = r.clips
            selectedAudioClip = r.added.id
        }
    }

    func deleteSelectedAudioClip() {
        guard let id = selectedAudioClip else { return }
        audioClipUndo.perform("Delete Audio Clip") {
            audioClips.removeAll { $0.id == id }
            selectedAudioClip = nil
        }
    }

    func clearAudioClips() {
        guard !audioClips.isEmpty else { return }
        audioClipUndo.perform("Clear Audio Clips") {
            audioClips = []
            selectedAudioClip = nil
        }
    }

    /// Selects a clip and puts the playhead at its start.
    func selectAudioClip(_ id: UUID, seek: Bool = true) {
        selectedAudioClip = id
        guard seek, let c = audioClips.first(where: { $0.id == id }) else { return }
        position = c.start
        scrub(to: c.start)
        endScrub(at: c.start)
    }

    /// Inspector edit of the selected clip's times, explicit end (rejected values leave it as it was).
    func editSelectedAudioClip(start: Double, end: Double) {
        guard let id = selectedAudioClip else { return }
        guard let new = AudioClipEdit.setRange(audioClips, id: id, start: start, end: end, duration: duration) else {
            objectWillChange.send()   // let the fields snap back
            return
        }
        guard new != audioClips else { return }
        audioClipUndo.perform("Edit Audio Clip") { audioClips = new }
    }

    /// Changes any field of the selected clip (file, offset, fades, volume; undoable). The result is run through the
    /// validator (`AudioClipEdit.normalize`); a change of the times is rejected unless it is a valid range. Repeated
    /// edits with the same `name` within a second collapse into one undo step (e.g. dragging a volume slider).
    func editSelectedAudioClip(name: String, _ change: (inout AudioClip) -> Void) {
        guard let id = selectedAudioClip, let i = audioClips.firstIndex(where: { $0.id == id }) else { return }
        var new = audioClips
        let old = new[i]
        change(&new[i])
        new[i].id = old.id
        if new[i].start != old.start || new[i].end != old.end {
            guard let ranged = AudioClipEdit.setRange(new, id: id, start: new[i].start, end: new[i].end, duration: duration) else {
                objectWillChange.send()
                return
            }
            new = ranged
        } else {
            AudioClipEdit.normalize(&new[i])
        }
        guard new != audioClips else { return }
        let before = AudioClipSnapshot(clips: audioClips, selected: selectedAudioClip)
        audioClips = new
        let now = Date()
        if let last = lastAudioClipEdit, last.name == name, now.timeIntervalSince(last.at) < 1 { lastAudioClipEdit = (name, now); return }
        lastAudioClipEdit = (name, now)
        audioClipUndo.register(before, name)
    }

    func beginAudioClipDrag() { audioClipDragStart = AudioClipSnapshot(clips: audioClips, selected: selectedAudioClip) }

    func dragAudioClip(_ id: UUID, edge: RegionEdit.Edge, to time: Double) {
        audioClips = AudioClipEdit.moveEdge(audioClips, id: id, edge: edge, to: time, duration: duration)
    }

    func dragAudioClip(_ id: UUID, toStart start: Double) {
        audioClips = AudioClipEdit.move(audioClips, id: id, toStart: start, duration: duration)
    }

    func endAudioClipDrag(name: String = "Resize Audio Clip") {
        defer { audioClipDragStart = nil }
        guard let before = audioClipDragStart, before.clips != audioClips else { return }
        audioClipUndo.register(before, name)
    }
}

@MainActor
struct AudioClipTimeline: TimelineAdapter {
    let model: PlayerModel
    var kind: TimelineKind { .audio }
    var items: [TimelineItem] { model.audioClips.map { TimelineItem(id: $0.id, start: $0.start, end: $0.end, label: $0.displayName) } }
    var selected: UUID? { model.selectedAudioClip }
    var addTitle: String { "Add audio" }
    var deleteTitle: String { "Delete audio" }
    var clearTitle: String { "Clear audio" }
    var addTip: String { "Add an audio clip of 3 s at the playhead (choose its file in the Inspector tab); drag its handles on the seekbar to resize. Clips may overlap and are mixed." }
    var deleteTip: String { "Delete the selected audio clip (Delete)" }
    var clearTip: String { "Remove all audio clips" }
    var canAdd: Bool { model.duration > 0 }
    var canDelete: Bool { model.selectedAudioClip != nil }
    var canClear: Bool { !model.audioClips.isEmpty }
    var deleteConfirm: (String, String) { ("Delete the selected audio clip?", "The audio file itself is not touched. You can undo it with Edit > Undo.") }
    var clearConfirm: (String, String) { ("Clear all audio clips?", "All audio clips are removed from this video (the audio files are not touched). You can undo it with Edit > Undo.") }
    func select(_ id: UUID) { model.selectAudioClip(id) }
    func selectQuietly(_ id: UUID) { model.selectAudioClip(id, seek: false) }
    func add() { model.addAudioClip() }
    func deleteSelected() { model.deleteSelectedAudioClip() }
    func clear() { model.clearAudioClips() }
    func beginDrag() { model.beginAudioClipDrag() }
    func drag(_ id: UUID, edge: RegionEdit.Edge, to time: Double) { model.dragAudioClip(id, edge: edge, to: time) }
    func dragRegion(_ id: UUID, to start: Double) { model.dragAudioClip(id, toStart: start) }
    func endMove() { model.endAudioClipDrag(name: "Move Audio Clip") }
    func endDrag() { model.endAudioClipDrag() }
}
