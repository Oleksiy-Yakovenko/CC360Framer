import AVFoundation
import Foundation

/// Preview playback of the user's audio clips. A dedicated second `AVPlayer` (the "clip player") plays the clips-only
/// mix on the SOURCE timeline (`AudioExport.build` with no source tracks and no time map, so item time = source time).
/// The MAIN player is the master: this class never touches the main composition, its audio mix or the dissolve spare
/// player; cut skips, scrubs and dissolves just look like the main time moving, and the clip player follows it
/// (explicit calls from `PlayerModel` plus a drift check while playing).
///
/// Sync design (see `AudioClipSync`): after any seek or rebuild the clip player is positioned PAUSED at the main time and
/// only started by the drift check once the main player really runs (rate > 0 and `timeControlStatus == .playing`; the
/// video composition can take much longer to start than this audio-only player), a little ahead of it to cover its own
/// start latency. Small drift is removed by nudging the clip player's rate by +/-4 %; only a jump re-seeks. A re-seek of
/// the running player restarts its audio and takes longer than the check interval, which made the old threshold re-seek
/// fire again and again (audible periodic wobble) whenever the clip player had started inside the item.
@MainActor
final class AudioClipPlayback {
    private let player = AVPlayer()
    /// Keeps the clip file assets of the current item alive.
    private var built: AudioExport.Built?
    /// The clips and duration `built` was made from (volume / fade changes are applied to its mix in place).
    private var builtClips: [AudioClip] = []
    private var builtDuration = 0.0
    private var rebuildPending = false
    /// A seek of the clip player is in flight: the drift check waits for it.
    private var seeking = false
    /// The clip player's current rate relative to normal (1 = not nudged).
    private var clipRate = 1.0
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
    /// The main player really plays right now (not buffering or seeking).
    var mainRunning: () -> Bool = { true }

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
            rebuildPending = false
            apply(nil, duration: 0, clips: [])
            return
        }
        // Volume / fade edits only change the audio mix: swap it on the live item, no restart, no rebuild.
        if !rebuildPending, let built, duration == builtDuration, !AudioClipSync.needsRebuild(old: builtClips, new: clips),
           let mix = AudioExport.remix(built, clips: clips, sourceDuration: duration) {
            rebuildTask = nil
            player.currentItem?.audioMix = mix
            builtClips = clips
            return
        }
        rebuildPending = true
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RebuildGate.debounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let box = await Task.detached(priority: .userInitiated) { () -> UncheckedBox<AudioExport.Built?> in
                // Built (AVFoundation objects) is created here and only touched afterwards on the main actor.
                UncheckedBox((try? AudioExport.build(source: nil, trackIDs: [], map: nil, sourceDuration: duration, clips: clips)) ?? nil)
            }.value
            guard let self, !Task.isCancelled, self.gate.isCurrent(token) else { return }
            self.rebuildPending = false
            self.apply(box.value, duration: duration, clips: clips)
        }
    }

    private func apply(_ new: AudioExport.Built?, duration: Double, clips: [AudioClip]) {
        seekToken += 1
        seeking = false
        clipRate = 1
        built = new
        builtClips = clips
        builtDuration = duration
        guard let new else {
            player.pause()
            player.replaceCurrentItem(with: nil)
            itemDuration = 0
            stopTimer()
            return
        }
        let item = AVPlayerItem(asset: new.composition)
        item.audioMix = new.mix
        item.audioTimePitchAlgorithm = .timeDomain   // +/-4 % nudges stay inaudible
        player.replaceCurrentItem(with: item)
        itemDuration = duration
        resync()
        if mainPlaying() { startTimer() }
    }

    // MARK: Following the main player

    /// The main player started playing (at its current time, or `time`).
    func play(at time: Double? = nil) {
        guard itemDuration > 0 else { return }
        startTimer()
        resync(time: time)
    }

    func pause() {
        stopTimer()
        seekToken += 1
        seeking = false
        clipRate = 1
        player.pause()
    }

    /// Scrubbing: silent, follows the position loosely.
    func scrub(to time: Double) {
        guard itemDuration > 0 else { return }
        seekToken += 1
        seeking = false
        clipRate = 1
        player.pause()
        player.seek(to: cm(min(max(time, 0), itemDuration)), toleranceBefore: cm(0.2), toleranceAfter: cm(0.2))
    }

    /// The main player was seeked exactly (end of scrub, cut skip, jump): follow it and resume if it plays.
    func seek(to time: Double) {
        guard itemDuration > 0 else { return }
        resync(time: time)
        if mainPlaying() { startTimer() }
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
        builtClips = []
        rebuildPending = false
        seeking = false
        clipRate = 1
        itemDuration = 0
    }

    private func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

    /// Pauses the clip player and seeks it exactly to `time` (default: the main time). It is NOT started here: the drift
    /// check starts it when the main player really runs.
    private func resync(time: Double? = nil) {
        let t = min(max(time ?? mainTime(), 0), itemDuration)
        seekToken += 1
        let token = seekToken
        clipRate = 1
        player.pause()
        seeking = true
        player.seek(to: cm(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, token == self.seekToken else { return }
                self.seeking = false
            }
        }
    }

    /// Follow check while the main player plays (and while it is about to).
    private func tick() {
        guard itemDuration > 0 else { return }
        if !mainPlaying() { stopTimer(); return }
        guard !seeking else { return }
        let acts = sync.actions(mainTime: mainTime(), mainPlaying: true, mainRunning: mainRunning(), scrubbing: mainScrubbing(),
                                clipTime: player.currentTime().seconds, clipPlaying: player.rate != 0, clipRate: clipRate,
                                clipDuration: itemDuration)
        var i = 0
        while i < acts.count {
            switch acts[i] {
            case .seek(let t):
                seekClip(to: t, thenPlay: false)
            case .start(let t):
                seekClip(to: t, thenPlay: true)
            case .play: player.play()
            case .pause: player.pause(); clipRate = 1
            case .setRate(let r):
                clipRate = r
                if player.rate != 0 { player.rate = Float(r) }
            }
            i += 1
        }
    }

    private func seekClip(to t: Double, thenPlay: Bool) {
        seekToken += 1
        let token = seekToken
        seeking = true
        player.seek(to: cm(t), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, token == self.seekToken else { return }
                self.seeking = false
                if thenPlay { self.clipRate = 1; self.player.rate = 1 }
            }
        }
    }

    private func startTimer() {
        guard driftTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
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
