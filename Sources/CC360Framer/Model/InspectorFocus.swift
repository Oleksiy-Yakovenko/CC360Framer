import Foundation

/// Decides whether the Inspector forms must drop an in-progress text edit because a different
/// item (keyframe, cut, card, caption) is now selected than the one the fields last showed.
enum InspectorFocus {
    /// `shown`: identity the form last displayed (nil = nothing); `selected`: identity now selected (nil = nothing).
    /// True only when an item is selected and it differs from the one shown, so typing in the
    /// same item is never clobbered while a switch always discards the old text.
    static func shouldResetFields<ID: Equatable>(shown: ID?, selected: ID?) -> Bool {
        guard let selected else { return false }
        return shown != selected
    }
}
