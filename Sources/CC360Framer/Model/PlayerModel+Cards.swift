import Foundation

/// Location card keyframes: editing (all undoable through `cardKeyUndo`) and the timeline adapter.
extension PlayerModel {
    /// Called when the card keyframes or the automatic-card switch change: refresh the overlays and persist.
    func cardsChanged() {
        guard !loadingProjectFlag else { return }
        rebuildOverlays()
        saveProject()
    }

    var selectedCardKeyValue: LocationCardKey? { selectedCardKey.flatMap { id in cardKeys.first { $0.id == id } } }

    /// Adds a card at the playhead; it inherits the placement chosen in the Location tab.
    func addCardKey() {
        guard duration > 0 else { return }
        guard let r = LocationCards.add(cardKeys, at: position, duration: duration) else {
            statusText = "There is already a location card at the playhead."
            return
        }
        cardKeyUndo.perform("Add Location Card") {
            cardKeys = r.keys
            selectedCardKey = r.added.id
        }
    }

    func deleteSelectedCardKey() {
        guard let id = selectedCardKey else { return }
        cardKeyUndo.perform("Delete Location Card") {
            cardKeys.removeAll { $0.id == id }
            selectedCardKey = nil
        }
    }

    func clearCardKeys() {
        guard !cardKeys.isEmpty else { return }
        cardKeyUndo.perform("Clear Location Cards") {
            cardKeys = []
            selectedCardKey = nil
        }
    }

    /// Selects a card keyframe and puts the playhead there.
    func selectCardKey(_ id: UUID) {
        selectedCardKey = id
        guard let k = cardKeys.first(where: { $0.id == id }) else { return }
        position = k.time
        scrub(to: k.time)
        endScrub(at: k.time)
    }

    /// Inspector edit of the selected card keyframe (rejected values leave it as it was).
    func editSelectedCardKey(time: Double, placement: OverlayPlacement?) {
        guard let id = selectedCardKey else { return }
        guard let new = LocationCards.set(cardKeys, id: id, time: time, placement: placement, duration: duration) else {
            objectWillChange.send()   // let the fields snap back
            return
        }
        guard new != cardKeys else { return }
        let moved = new.first { $0.id == id }?.time != cardKeys.first { $0.id == id }?.time
        cardKeyUndo.perform("Edit Location Card") { cardKeys = new }
        if moved, let t = new.first(where: { $0.id == id })?.time { scrub(to: t); endScrub(at: t) }
    }

    /// Turns the placement override of the selected card on (starting from the inherited global placement) or off (undoable).
    func setSelectedCardOverride(_ on: Bool) {
        guard let k = selectedCardKeyValue, (k.placement != nil) != on else { objectWillChange.send(); return }
        guard let id = selectedCardKey,
              let new = LocationCards.set(cardKeys, id: id, time: k.time, placement: on ? overlayPlacement : nil, duration: duration) else { return }
        cardKeyUndo.perform(on ? "Override Location Card Placement" : "Inherit Location Card Placement") { cardKeys = new }
    }

    /// Switches the automatic card at t = 0 on or off (undoable).
    func setAutoLocationCard(_ on: Bool) {
        guard on != autoLocationCard else { return }
        cardKeyUndo.perform(on ? "Enable Automatic Location Card" : "Disable Automatic Location Card") { autoLocationCard = on }
    }
}

@MainActor
struct LocationCardTimeline: TimelineAdapter {
    let model: PlayerModel
    var kind: TimelineKind { .locationCards }
    var items: [TimelineItem] { model.cardKeys.map { TimelineItem(id: $0.id, start: $0.time, end: nil) } }
    var selected: UUID? { model.selectedCardKey }
    var addTitle: String { "Add card" }
    var deleteTitle: String { "Delete card" }
    var clearTitle: String { "Clear cards" }
    var addTip: String { "Show the location card for 10 s starting at the playhead, with the placement chosen in the Location tab (a card can override it in the Inspector tab). Once a card exists, only the cards on this timeline are shown (the automatic card at the start is ignored)." }
    var deleteTip: String { "Delete the selected location card (Delete)" }
    var clearTip: String { "Remove all location cards; the automatic card at the start applies again" }
    var canAdd: Bool { model.duration > 0 && model.place != nil }
    var canDelete: Bool { model.selectedCardKey != nil }
    var canClear: Bool { !model.cardKeys.isEmpty }
    var deleteConfirm: (String, String) { ("Delete the selected location card?", "You can undo it with Edit > Undo.") }
    var clearConfirm: (String, String) { ("Clear all location cards?", "The automatic card at the start applies again. You can undo it with Edit > Undo.") }
    func select(_ id: UUID) { model.selectCardKey(id) }
    func add() { model.addCardKey() }
    func deleteSelected() { model.deleteSelectedCardKey() }
    func clear() { model.clearCardKeys() }
}
