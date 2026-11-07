import Foundation

/// Pure decisions for the audio clip preview player ("clip player"), which is slaved to the main player: the main
/// player's source time is the master and the clip player must follow it.
///
/// Why drift is corrected softly: a hard re-seek of the clip player restarts its audio (a gap / level dip), and the
/// seek itself takes time, during which the main player moves on, so with a threshold re-seek the clip player was
/// re-seeked again and again (every check) once it had started inside the item: an audible periodic wobble. Small drift
/// is therefore removed by running the clip player slightly faster or slower; only a jump re-seeks.
struct AudioClipSync {
    /// Drift (seconds) below which nothing is done.
    var okDrift = 0.03
    /// While nudging, the rate returns to normal once the drift is below this.
    var settledDrift = 0.01
    /// Drift above which the clip player is re-seeked (a jump, not a slow slip).
    var seekDrift = 0.5
    /// Rate change used to catch up / wait (4 % = inaudible with the time-domain pitch algorithm).
    var nudge = 0.04
    /// A paused clip player further than this from the main time is re-seeked.
    var pausedTolerance = 0.02
    /// The clip player is started this much ahead of the main time (its start latency).
    var startLead = 0.05

    /// A scrub only silences the clip player while the position keeps changing: the main player goes on playing while the
    /// mouse is held still, and the clip player must follow it then.
    static let scrubIdle = 0.25
    static func isActivelyScrubbing(scrubbing: Bool, secondsSinceLastScrubMove: Double) -> Bool {
        scrubbing && secondsSinceLastScrubMove < scrubIdle
    }

    enum Action: Equatable {
        case seek(Double)
        case play
        case pause
        /// Seek there, then play from there (once the seek finished).
        case start(at: Double)
        /// Change the clip player's rate to this multiple of the main rate (1 = normal).
        case setRate(Double)
    }

    enum Drift: Equatable {
        case ok
        case nudge(rate: Double)
        case seek
    }

    /// Classifies `drift` = clip time - target time (positive = the clip is ahead). `nudging` = the clip player currently
    /// runs at a corrected rate (hysteresis: it keeps correcting until the drift is `settledDrift`).
    func classify(drift: Double, nudging: Bool) -> Drift {
        let d = abs(drift)
        if d > seekDrift { return .seek }
        if d <= (nudging ? settledDrift : okDrift) { return .ok }
        return .nudge(rate: drift > 0 ? 1 - nudge : 1 + nudge)
    }

    /// What to do with the clip player so that it matches the main player. Actions apply in order.
    /// `mainPlaying` = the main player is meant to play; `mainRunning` = it really plays right now (rate > 0 and not
    /// buffering / seeking). While it is not running the clip player waits at the target. `clipRate` is the clip player's
    /// current rate relative to normal (1 = not nudged). `clipDuration` = length of its item (0 = no item: nothing to do).
    func actions(mainTime: Double, mainPlaying: Bool, mainRunning: Bool = true, scrubbing: Bool, clipTime: Double,
                 clipPlaying: Bool, clipRate: Double = 1, clipDuration: Double) -> [Action] {
        guard clipDuration > 0 else { return [] }
        let beyond = mainTime >= clipDuration
        let target = min(max(mainTime, 0), clipDuration)
        var out: [Action] = []
        if scrubbing || !mainPlaying || !mainRunning || beyond {
            if clipPlaying { out.append(.pause) }
            if abs(clipTime - target) > pausedTolerance { out.append(.seek(target)) }
            return out
        }
        if !clipPlaying {
            out.append(.start(at: min(target + startLead, clipDuration)))
            if clipRate != 1 { out.append(.setRate(1)) }
            return out
        }
        let nudging = abs(clipRate - 1) > 1e-9
        switch classify(drift: clipTime - target, nudging: nudging) {
        case .ok: if nudging { out.append(.setRate(1)) }
        case .nudge(let r): if abs(r - clipRate) > 1e-9 { out.append(.setRate(r)) }
        case .seek: out.append(.seek(min(target + startLead, clipDuration))); if nudging { out.append(.setRate(1)) }
        }
        return out
    }

    /// True when the preview item must be rebuilt for the change from `old` to `new`: the composition depends on each
    /// clip's id, path, start, end and file offset (and on which clips exist). Volume and fades only change the audio mix,
    /// which can be swapped on the live item.
    static func needsRebuild(old: [AudioClip], new: [AudioClip]) -> Bool {
        guard old.count == new.count else { return true }
        for (a, b) in zip(old, new) where a.id != b.id || a.path != b.path || a.start != b.start || a.end != b.end || a.fileOffset != b.fileOffset {
            return true
        }
        return false
    }

    /// True when a freshly planned set of pieces has the same layout (clip, file position, placement, length) as the built
    /// ones, so only the volumes differ and the existing composition tracks can be reused.
    static func piecesMatch(_ a: [AudioMixPlan.Piece], _ b: [AudioMixPlan.Piece]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy {
            $0.clipID == $1.clipID && $0.path == $1.path && abs($0.fileStart - $1.fileStart) < 1e-9
                && abs($0.outputStart - $1.outputStart) < 1e-9 && abs($0.length - $1.length) < 1e-9
        }
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
