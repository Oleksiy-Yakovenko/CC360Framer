import AVFoundation
import AppKit

/// State of the preview dissolve: a spare player that shows the incoming part of a cut while the main player finishes the
/// outgoing one (see `TimeMap.Overlap`). All of it lives on the main actor.
///
/// Design: the main player always plays the SOURCE timeline (playhead, seekbar, camera path, stabiliser, overlays all keep
/// using source time). Shortly before a dissolve window the spare player is positioned at the incoming segment's start
/// (`prepared`); when the main playhead enters the window the spare starts (`armed`) and the renderer blends the two decoded
/// frames in the shader with the export's weight. At the end of the window the spare is already playing at the right place,
/// so the two players swap roles instead of seeking (no hitch, no double audio): the spare becomes the main player.
@MainActor
final class DissolveState {
    /// A second player with its own item and frame output on the same composition.
    final class Lane {
        var player = AVPlayer()
        var item: AVPlayerItem?
        var output: AVPlayerItemVideoOutput?
        init() { player.automaticallyWaitsToMinimizeStalling = false }
    }

    /// Preview map with the export crossfade; nil while dissolves are off (checkbox off, crossfade 0, no cuts).
    var map: TimeMap?
    var spare: Lane?
    /// Spare is positioned at the start of this window (not playing yet).
    var prepared: TimeMap.Overlap?
    /// Main playhead is inside this window and the spare shows the incoming part.
    var armed: TimeMap.Overlap?
    var spareRunning = false
    var seekInFlight = false
    /// Identifies the latest spare seek; a completion of an older one is ignored. `onSeek` runs when the latest finishes.
    var seekToken = 0
    var onSeek: (() -> Void)?
    /// Source time the spare was last asked to show (paused syncing).
    var lastTarget = 0.0
    var lastSeekAt = 0.0

    /// Seconds before a window at which the spare is positioned.
    static let lead = 2.0
    /// Playing drift between the players that triggers a re-seek.
    static let drift = 0.25

    /// Stops and drops the spare player and clears the renderer feed (document close, new file).
    func release(frames: FrameSource) {
        spare?.player.pause()
        spare?.player.replaceCurrentItem(with: nil)
        spare = nil
        map = nil; prepared = nil; armed = nil; spareRunning = false; seekInFlight = false; onSeek = nil; seekToken += 1
        frames.overlap = nil; frames.incomingOutput = nil; frames.promotePending = false; frames.generation += 1
    }
}

extension PlayerModel {
    /// Crossfade length the preview uses: the export setting.
    var previewCrossfade: Double { exportSettings.crossfade }

    private var debugDissolve: Bool { ProcessInfo.processInfo.environment["CC360_DEBUG"] != nil }

    /// Rebuilds the dissolve map from the cuts, the checkbox and the crossfade; always starts from a clean state.
    func configureDissolve() {
        disarmDissolve()
        frames.incomingCamera = { [weak self] t in
            MainActor.assumeIsolated { self?.incomingCamera(at: t) ?? (yaw: 0, pitch: 0, fov: 70) }
        }
        let m = timeMap(crossfade: previewCrossfade)
        if previewWithCuts, previewCrossfade > 0, !m.overlaps.isEmpty, item != nil {
            dissolve.map = m
            _ = ensureSpare()   // building the second item takes a while: do it now, not in the middle of playback
        } else {
            dissolve.release(frames: frames)
        }
    }

    /// Camera of the incoming frame (source time `t`): the path sampled at that time while following, else the user's view.
    private func incomingCamera(at t: Double) -> (yaw: Float, pitch: Float, fov: Float) {
        let cur = (yaw: viewState.yaw, pitch: viewState.pitch, fov: viewState.fovDegrees)
        guard autoFollow else { return cur }
        return path.sample(at: t, global: globalFov, fallback: cur)
    }

    private func ensureSpare() -> DissolveState.Lane? {
        if let s = dissolve.spare { return s }
        guard let composition, let videoComposition else { return nil }
        let lane = DissolveState.Lane()
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        lane.item = item
        lane.output = output
        lane.player.replaceCurrentItem(with: item)
        dissolve.spare = lane
        applyDissolveAudio()
        return lane
    }

    /// Sets the audio mixes of both players: the enabled tracks at full volume, with a fade-out ramp on the main item and a
    /// fade-in ramp on the spare item over the prepared / armed window (same linear ramp as the export).
    func applyDissolveAudio() {
        let ov = dissolve.armed ?? dissolve.prepared
        func range(_ start: Double, _ length: Double) -> CMTimeRange {
            CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 48000), duration: CMTime(seconds: length, preferredTimescale: 48000))
        }
        item?.audioMix = ov.flatMap { session?.audioMix(for: audioOptions, ramp: (range($0.outStart, $0.length), 1, 0)) } ?? audioMix()
        dissolve.spare?.item?.audioMix = ov.flatMap { session?.audioMix(for: audioOptions, ramp: (range($0.inStart, $0.length), 0, 1)) } ?? audioMix()
    }

    /// Moves the spare to `time` (source) and runs `then` once it got there (`then` is skipped if the state changed meanwhile).
    private func seekSpare(to time: Double, flexible: Bool = false, then: (() -> Void)? = nil) {
        guard let spare = dissolve.spare else { return }
        let d = dissolve
        d.seekInFlight = true
        d.seekToken += 1
        d.onSeek = then
        let token = d.seekToken
        d.lastTarget = time
        d.lastSeekAt = CACurrentMediaTime()
        let tol = flexible ? CMTime(seconds: 0.1, preferredTimescale: 600) : .zero
        spare.player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tol, toleranceAfter: tol) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.dissolve.seekToken == token else { return }
                self.dissolve.seekInFlight = false
                let next = self.dissolve.onSeek
                self.dissolve.onSeek = nil
                next?()
            }
        }
    }

    private func prepareDissolve(_ ov: TimeMap.Overlap) {
        guard let spare = ensureSpare() else { return }
        dissolve.prepared = ov
        dissolve.spareRunning = false
        applyDissolveAudio()
        // All the slow work (seek, decoder start-up, preroll) happens here, well ahead of the window; arming only starts the clock.
        spare.player.pause()
        seekSpare(to: ov.inStart) { [weak self] in self?.dissolve.spare?.player.preroll(atRate: 1) { _ in } }
        if debugDissolve { print("dissolve: prepared window \(ov.outStart)-\(ov.outEnd) -> incoming from \(ov.inStart)"); fflush(stdout) }
    }

    private func armDissolve(_ ov: TimeMap.Overlap, at t: Double) {
        guard let spare = ensureSpare() else { return }
        let d = dissolve
        let wasPrepared = d.prepared == ov
        d.armed = ov
        d.prepared = ov
        frames.overlap = ov
        frames.incomingOutput = spare.output
        frames.generation += 1
        if !wasPrepared { applyDissolveAudio() }   // the prepared phase already set the same mixes
        let expected = ov.incomingTime(forOutgoing: t)
        let ready = wasPrepared && !d.seekInFlight && abs(d.lastTarget - expected) < 0.1
        if !ready {
            spare.player.pause()
            d.spareRunning = false
            seekSpare(to: expected, flexible: scrubbing) { [weak self] in self?.startSpareIfPlaying() }
        } else {
            startSpareIfPlaying()
        }
        if debugDissolve { print("dissolve: armed at t=\(t) (window \(ov.outStart)-\(ov.outEnd), incoming \(expected))"); fflush(stdout) }
    }

    /// Starts the spare at host-clock precision so that it is at the incoming time matching the main playhead: a plain
    /// `play()` takes a few hundred ms to deliver the first frame and would leave the incoming part behind.
    private func startSpareIfPlaying() {
        guard let spare = dissolve.spare, let ov = dissolve.armed, isPlaying, !dissolve.spareRunning else { return }
        let main = viewState.frameTime
        let delay = 0.05
        let at = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: delay, preferredTimescale: 1000))
        let time = CMTime(seconds: ov.incomingTime(forOutgoing: main + delay), preferredTimescale: 600)
        spare.player.setRate(1, time: time, atHostTime: at)
        dissolve.spareRunning = true
    }

    /// Keeps the spare in lock-step with the main player while a window is armed (also while paused or scrubbing).
    private func syncSpare(_ ov: TimeMap.Overlap, at t: Double) {
        let d = dissolve
        guard let spare = d.spare, d.armed == ov, !d.seekInFlight else { return }
        let expected = ov.incomingTime(forOutgoing: t)
        if isPlaying {
            if !d.spareRunning { startSpareIfPlaying(); return }
            if let shown = frames.lastIncomingTime, abs(shown - expected) > DissolveState.drift, CACurrentMediaTime() - d.lastSeekAt > 0.5 {
                spare.player.pause()
                d.spareRunning = false
                seekSpare(to: expected) { [weak self] in self?.startSpareIfPlaying() }
            }
        } else {
            if d.spareRunning { spare.player.pause(); d.spareRunning = false }
            if abs(expected - d.lastTarget) > 0.04 { seekSpare(to: expected, flexible: scrubbing) }
        }
    }

    /// Back to the plain single-player preview (window left without finishing, checkbox off, edits).
    func disarmDissolve() {
        let d = dissolve
        guard d.armed != nil || d.prepared != nil || d.spareRunning else { return }
        d.spare?.player.pause()
        d.armed = nil; d.prepared = nil; d.spareRunning = false
        d.seekToken += 1; d.seekInFlight = false; d.onSeek = nil
        frames.overlap = nil; frames.incomingOutput = nil; frames.generation += 1
        applyDissolveAudio()
        if debugDissolve { print("dissolve: disarmed"); fflush(stdout) }
    }

    /// The dissolve is over and the spare is playing the incoming part: swap the players' roles (no seek, no gap).
    private func completeDissolve(_ ov: TimeMap.Overlap) {
        let d = dissolve
        guard let spare = d.spare, let newItem = spare.item else { disarmDissolve(); return }
        removePlayerObservers()
        // Swap the roles: the spare (already playing the incoming part) becomes the main player, the old main one the next spare.
        let old = (player: player, item: item, output: frames.output)
        player = spare.player
        item = newItem
        frames.output = spare.output
        spare.player = old.player
        spare.item = old.item
        spare.output = old.output
        spare.player.pause()
        // Only a player that does not wait to minimise stalling can start on a host time (`setRate(_:time:atHostTime:)`
        // blocks otherwise); the main player keeps the default.
        spare.player.automaticallyWaitsToMinimizeStalling = false
        player.automaticallyWaitsToMinimizeStalling = true
        // The new main player keeps running (it was started with the window); make sure it is.
        if isPlaying { player.play() }
        d.armed = nil; d.prepared = nil; d.spareRunning = false
        d.seekToken += 1; d.seekInFlight = false; d.onSeek = nil
        frames.overlap = nil; frames.incomingOutput = nil; frames.generation += 1
        frames.promotePending = true
        applyDissolveAudio()
        rebindPlayerObservers()
        if debugDissolve { print("dissolve: swapped players at t=\(player.currentTime().seconds) (window ended at \(ov.outEnd), landing \(ov.landing))"); fflush(stdout) }
    }

    /// Called every draw (display link) before the frame is picked: arms, syncs, completes and disarms dissolve windows.
    func dissolveTick() {
        guard let map = dissolve.map else {
            if dissolve.armed != nil { disarmDissolve() }
            return
        }
        guard item != nil, previewWithCuts else { disarmDissolve(); return }
        // The time of the frame on screen, not `player.currentTime()`: that call blocks for tens of ms while the other
        // player is seeking or starting, which would stall the display link.
        let t = viewState.frameTime
        guard t.isFinite else { return }
        if let ov = map.overlap(atOutgoingSource: t) {
            if dissolve.armed != ov { armDissolve(ov, at: t) }
            syncSpare(ov, at: t)
        } else if let ov = dissolve.armed {
            if isPlaying, dissolve.spareRunning, t >= ov.outEnd, t < ov.outEnd + 0.5 { completeDissolve(ov) } else { disarmDissolve() }
        } else if isPlaying, let next = map.nextOverlap(after: t), next.outStart - t <= DissolveState.lead {
            if dissolve.prepared != next { prepareDissolve(next) }
        }
    }
}
