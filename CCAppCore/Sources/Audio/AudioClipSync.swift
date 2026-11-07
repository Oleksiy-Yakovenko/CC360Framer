import Foundation

/// Pure decisions for the audio clip preview player ("clip player"), which is slaved to the main player: the main
/// player's source time is the master and the clip player must follow it.
struct AudioClipSync {
    /// Playing drift between the players that triggers a re-seek.
    var driftThreshold = 0.08
    /// A paused clip player further than this from the main time is re-seeked.
    var pausedTolerance = 0.02

    enum Action: Equatable {
        case seek(Double)
        case play
        case pause
    }

    /// What to do with the clip player so that it matches the main player. Actions apply in order.
    /// `clipDuration` is the length of the clip player's item (0 = no item: nothing to do).
    func actions(mainTime: Double, mainPlaying: Bool, scrubbing: Bool, clipTime: Double, clipPlaying: Bool,
                 clipDuration: Double) -> [Action] {
        guard clipDuration > 0 else { return [] }
        let beyond = mainTime >= clipDuration
        let target = min(max(mainTime, 0), clipDuration)
        var out: [Action] = []
        if scrubbing || !mainPlaying || beyond {
            if clipPlaying { out.append(.pause) }
            if abs(clipTime - target) > pausedTolerance { out.append(.seek(target)) }
            return out
        }
        if abs(clipTime - target) > driftThreshold { out.append(.seek(target)) }
        if !clipPlaying { out.append(.play) }
        return out
    }
}

/// Generation counter for the debounced background rebuild: only the latest request may be applied.
struct RebuildGate {
    private(set) var generation = 0
    /// Debounce between the last clip change and the rebuild.
    static let debounce = 0.3

    mutating func request() -> Int {
        generation += 1
        return generation
    }
    func isCurrent(_ token: Int) -> Bool { token == generation }
}
