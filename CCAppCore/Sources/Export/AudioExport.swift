import AVFoundation

/// Builds the audio of an export: ONE composition holding the enabled source (.360) audio tracks and one composition
/// track per clip piece (see `AudioMixPlan`), ONE audio mix with parameters for all of them. The Exporter reads it
/// through one `AVAssetReaderAudioMixOutput`, which requires that every track belongs to the reader's asset.
enum AudioExport {
    struct Built {
        let composition: AVMutableComposition
        let mix: AVAudioMix
        let tracks: [AVAssetTrack]
        /// Clips left out because their file is missing, has no audio or no path.
        let skipped: Int
        /// The plan pieces that got a composition track, with that track's ID (parallel arrays), and the probed file
        /// infos by path: lets the preview recompute the mix (volume / fades) without rebuilding the composition.
        var pieces: [AudioMixPlan.Piece] = []
        var pieceTrackIDs: [CMPersistentTrackID] = []
        var infos: [String: AudioFileInfo] = [:]
        /// The clip file assets stay alive as long as this value does.
        fileprivate let files: [AVURLAsset]
    }

    private final class Slot<T>: @unchecked Sendable { var value: T? }   // written by one task, read after the semaphore

    /// Opens an audio file and finds its first audio track. Blocking (the Exporter runs off the main thread): the async
    /// AVFoundation loading is bridged with a semaphore. The non-Sendable asset/track cross only through `Slot`, which
    /// is written once before the semaphore is signalled and read after it.
    private static func open(_ url: URL) -> (info: AudioFileInfo, asset: AVURLAsset, track: AVAssetTrack)? {
        let slot = Slot<(AudioFileInfo, AVURLAsset?, AVAssetTrack?)>()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: Task.currentPriority) {   // same priority as the waiting thread: no priority inversion
            var info = await AudioFileProbe.probe(url)
            var asset: AVURLAsset?, track: AVAssetTrack?
            if info.isUsable {
                let a = AVURLAsset(url: url)
                if let t = try? await a.loadTracks(withMediaType: .audio).first { asset = a; track = t } else { info.hasAudio = false }
            }
            slot.value = (info, asset, track)
            done.signal()
        }
        done.wait()
        guard let (info, asset, track) = slot.value, let asset, let track else { return nil }
        return (info, asset, track)
    }

    /// `source` supplies the enabled .360 audio tracks (`trackIDs`; may be nil/empty when only clips are exported).
    /// `map` nil = no cuts. Returns nil when there is nothing to play at all.
    static func build(source: AVComposition?, trackIDs: [CMPersistentTrackID], map: TimeMap?, sourceDuration: Double,
                      clips: [AudioClip]) throws -> Built? {
        var opened: [String: (info: AudioFileInfo, asset: AVURLAsset, track: AVAssetTrack)] = [:]
        for clip in clips where !clip.path.isEmpty && opened[clip.path] == nil {
            if let o = open(URL(fileURLWithPath: clip.path)) { opened[clip.path] = o }
        }
        let plan = AudioMixPlan.make(clips: clips, duration: sourceDuration, map: map) { opened[$0.path]?.info }
        var built = try build(source: source, trackIDs: trackIDs, map: map, sourceDuration: sourceDuration, plan: plan,
                              files: opened.mapValues { ($0.asset, $0.track) })
        built?.infos = opened.mapValues { $0.info }
        return built
    }

    static func build(source: AVComposition?, trackIDs: [CMPersistentTrackID], map: TimeMap?, sourceDuration: Double,
                      plan: AudioMixPlan.Result, files: [String: (asset: AVURLAsset, track: AVAssetTrack)]) throws -> Built? {
        let comp = AVMutableComposition()
        var params: [AVMutableAudioMixInputParameters] = []
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 48000) }

        // Source tracks: kept segments back to back, overlapping by the dissolve length. Overlapping needs two composition
        // tracks per source track (a track cannot overlap itself); segments alternate between them and get matching
        // volume ramps. Without cuts the one segment is the whole clip (one lane, no ramps).
        let segments = map?.segments ?? [TimeMap.Segment(sourceStart: 0, sourceEnd: sourceDuration, outputStart: 0)]
        let fades = map?.fades ?? []
        if let source {
            for id in trackIDs {
                guard let src = source.track(withTrackID: id) else { continue }
                var lanes: [AVMutableCompositionTrack?] = [nil, nil]
                var lanePars: [AVMutableAudioMixInputParameters?] = [nil, nil]
                for (i, seg) in segments.enumerated() {
                    let lane = i % 2
                    if lanes[lane] == nil {
                        guard let l = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                        lanes[lane] = l
                        lanePars[lane] = AVMutableAudioMixInputParameters(track: l)
                    }
                    guard let l = lanes[lane], let p = lanePars[lane] else { continue }
                    try l.insertTimeRange(CMTimeRange(start: t(seg.sourceStart), duration: t(seg.length)), of: src, at: t(seg.outputStart))
                    // A lane is silent between its segments. A volume change exactly at a ramp start makes the mix glide in
                    // from the previous value (~25 ms burst at full level), so the 0 / 1 start values are set earlier, in the gap.
                    if i > 0, fades[i - 1] > 0 {
                        if i < 2 { p.setVolume(0, at: .zero) }
                        p.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: t(seg.outputStart), duration: t(fades[i - 1])))
                    }
                    if i < fades.count, fades[i] > 0 {
                        p.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: t(seg.outputEnd - fades[i]), duration: t(fades[i])))
                    }
                    if i + 2 < segments.count, fades[i + 1] > 0 {
                        p.setVolume(0, at: t(seg.outputEnd))       // the next segment of this lane fades in from silence
                    } else if i < fades.count, fades[i] > 0 {
                        p.setVolume(1, at: t(seg.outputEnd))       // the lane is silent here; a later segment must not inherit 0
                    }
                }
                params += lanePars.compactMap { $0 }
            }
        }

        // Clip pieces: one composition track each (pieces of overlapping clips and of a dissolve overlap in time).
        var keep: [AVURLAsset] = []
        var usedPieces: [AudioMixPlan.Piece] = []
        var usedIDs: [CMPersistentTrackID] = []
        for piece in plan.pieces {
            guard let file = files[piece.path],
                  let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try track.insertTimeRange(CMTimeRange(start: t(piece.fileStart), duration: t(piece.length)), of: file.track, at: t(piece.outputStart))
            keep.append(file.asset)
            usedPieces.append(piece); usedIDs.append(track.trackID)
            let p = clipParameters(piece, track: track)
            params.append(p)
        }
        let tracks = comp.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return Built(composition: comp, mix: mix, tracks: tracks, skipped: plan.skipped.count, pieces: usedPieces, pieceTrackIDs: usedIDs, files: keep)
    }

    private static func clipParameters(_ piece: AudioMixPlan.Piece, track: AVMutableCompositionTrack) -> AVMutableAudioMixInputParameters {
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 48000) }
        let p = AVMutableAudioMixInputParameters(track: track)
        // Start value from time 0 (the track is empty before the piece): a volume set exactly at the piece start would let
        // the mix glide in from the default 1.0, giving a ~25 ms burst at full level at the start of a fade-in.
        if let first = piece.volumes.first { p.setVolume(Float(first.volume), at: .zero) }
        for (a, b) in zip(piece.volumes, piece.volumes.dropFirst()) where b.time - a.time > 1e-6 {
            p.setVolumeRamp(fromStartVolume: Float(a.volume), toEndVolume: Float(b.volume),
                            timeRange: CMTimeRange(start: t(a.time), duration: t(b.time - a.time)))
        }
        return p
    }

    /// A new mix for the SAME composition of a clips-only `built` (preview), for clips whose volume / fades changed but
    /// not their path, times or file offset. nil when the new plan does not line up with the built pieces (rebuild then).
    static func remix(_ built: Built, clips: [AudioClip], sourceDuration: Double) -> AVAudioMix? {
        let plan = AudioMixPlan.make(clips: clips, duration: sourceDuration, map: nil) { built.infos[$0.path] }
        guard AudioClipSync.piecesMatch(built.pieces, plan.pieces) else { return nil }
        var params: [AVMutableAudioMixInputParameters] = []
        for (piece, id) in zip(plan.pieces, built.pieceTrackIDs) {
            guard let track = built.composition.track(withTrackID: id) else { return nil }
            params.append(clipParameters(piece, track: track))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = params
        return mix
    }
}
