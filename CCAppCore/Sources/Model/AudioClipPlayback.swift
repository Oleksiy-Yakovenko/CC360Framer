import AVFoundation
import Foundation

/// Preview playback of the user's audio clips. A dedicated second `AVPlayer` (the "clip player") plays the clips-only
/// mix on the SOURCE timeline (`AudioExport.build` with no source tracks and no time map, so item time = source time).
/// The MAIN player is the master: this class never touches the main composition, its audio mix or the dissolve spare
/// player; cut skips, scrubs and dissolves just look like the main time moving, and the clip player follows it
/// (explicit calls from `PlayerModel` plus a drift check while playing).
@MainActor
final class AudioClipPlayback {
    private let player = AVPlayer()
    /// Keeps the clip file assets of the current item alive.
    private var built: AudioExport.Built?
    private var itemDuration = 0.0
    private var gate = RebuildGate()
    private var rebuildTask: Task<Void, Never>?
    private var driftTimer: Timer?
    private var sync = AudioClipSync()
    private var seekToken = 0

    /// Main player's current source time, play state and scrub state (set by the owner).
    var mainTime: () -> Double = { 0 }
    var mainPlaying: () -> Bool = { false }
    var mainScrubbing: () -> Bool = { false }

    init() {
        player.automaticallyWaitsToMinimizeStalling = false
    }

    // MARK: Rebuild

    /// Rebuilds the item for `clips` (debounced; the build runs off the main thread; stale results are dropped).
    /// No clips or nothing playable = no item.
    func setClips(_ clips: [AudioClip], duration: Double) {
        let token = gate.request()
        rebuildTask?.cancel()
        guard !clips.isEmpty, duration > 0 else {
            rebuildTask = nil
            apply(nil, duration: 0)
            return
        }
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RebuildGate.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let box = await Task.detached(priority: .userInitiated) { () -> UncheckedBox<AudioExport.Built?> in
                // Built (AVFoundation objects) is created here and only touched afterwards on the main actor.
                UncheckedBox((try? AudioExport.build(source: nil, trackIDs: [], map: nil, sourceDuration: duration, clips: clips)) ?? nil)
            }.value
            guard let self, !Task.isCancelled, self.gate.isCurrent(token) else { return }
            self.apply(box.value, duration: duration)
        }
    }

    private func apply(_ new: AudioExport.Built?, duration: Double) {
        seekToken += 1
        built = new
        guard let new else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            itemDuration = 0
            stopTimer()
            return
        }
        let item = AVPlayerItem(asset: new.composition)
        item.audioMix = new.mix
        player.replaceCurrentItem(with: item)
        itemDuration = duration
        resync(forceSeek: true)
    }

    // MARK: Following the main player

    /// The main player started playing (at its current time, or `time`).
    func play(at time: Double? = nil) {
        guard itemDuration > 0 else { return }
        startTimer()
        resync(forceSeek: true, time: time, playing: true)
    }

    func pause() {
        stopTimer()
        seekToken += 1
        player.pause()
    }

    /// Scrubbing: silent, follows the position loosely.
    func scrub(to time: Double) {
        guard itemDuration > 0 else { return }
        seekToken += 1
        player.pause()
        player.seek(to: cm(min(max(time, 0), itemDuration)), toleranceBefore: cm(0.2), toleranceAfter: cm(0.2))
    }

    /// The main player was seeked exactly (end of scrub, cut skip, jump): follow it and resume if it plays.
    func seek(to time: Double) {
        guard itemDuration > 0 else { return }
        resync(forceSeek: true, time: time, playing: mainPlaying())
    }

    /// Stops and releases everything (opening another video, closing).
    func stop() {
        rebuildTask?.cancel(); rebuildTask = nil
        _ = gate.request()
        seekToken += 1
        stopTimer()
        player.pause()
        player.replaceCurrentItem(with: nil)
        built = nil
        itemDuration = 0
    }

    private func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    /// Seeks the clip player exactly to the (main) time and plays or pauses it, applying the pure decision for the rest.
    private func resync(forceSeek: Bool, time: Double? = nil, playing: Bool? = nil) {
        let t = min(max(time ?? mainTime(), 0), itemDuration)
        // An explicit `playing` wins over the scrub flag (end of scrub: the flag is still set while the exact seek runs).
        let wantPlay = (playing ?? (mainPlaying() && !mainScrubbing())) && t < itemDuration
        seekToken += 1
        let token = seekToken
        if !wantPlay { player.pause() }
        player.seek(to: cm(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, token == self.seekToken, wantPlay else { return }
                self.player.play()
            }
        }
    }

    /// Drift check while the main player plays.
    private func tick() {
        guard itemDuration > 0 else { return }
        let acts = sync.actions(mainTime: mainTime(), mainPlaying: mainPlaying(), scrubbing: mainScrubbing(),
                                clipTime: player.currentTime().seconds, clipPlaying: player.rate != 0,
                                clipDuration: itemDuration)
        for a in acts {
            switch a {
            case .seek(let t):
                seekToken += 1
                player.seek(to: cm(t), toleranceBefore: .zero, toleranceAfter: .zero)
            case .play: player.play()
            case .pause: player.pause()
            }
        }
        if !mainPlaying() { stopTimer() }
    }

    private func startTimer() {
        guard driftTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        driftTimer = timer
    }

    private func stopTimer() {
        driftTimer?.invalidate()
        driftTimer = nil
    }
}
