import AVFoundation

/// An opened `.360` file: the source asset, the two-lens stacking composition with all audio tracks and the video composition.
/// Used by `PlayerModel.open` (interactive player) and by `BatchJob` (headless batch), so both build exactly the same composition.
final class MediaSession {
    let url: URL
    let asset: AVURLAsset
    let videoTracks: [AVAssetTrack]
    let duration: CMTime
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    /// One entry per audio track of the source; only the first starts enabled.
    let audioOptions: [AudioOption]
    private var tempDir: URL?

    private init(url: URL, asset: AVURLAsset, videoTracks: [AVAssetTrack], duration: CMTime, composition: AVMutableComposition,
                 videoComposition: AVMutableVideoComposition, audioOptions: [AudioOption], tempDir: URL?) {
        self.url = url; self.asset = asset; self.videoTracks = videoTracks; self.duration = duration
        self.composition = composition; self.videoComposition = videoComposition; self.audioOptions = audioOptions
        self.tempDir = tempDir
    }

    deinit { cleanup() }

    /// Removes the temporary symlink directory (if the symlink fallback was needed).
    func cleanup() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    static func open(_ url: URL) async throws -> MediaSession {
        let (asset, tracks, duration, tempDir) = try await loadAsset(url)
        let videos = tracks.filter { $0.mediaType == .video }
        guard videos.count == 2 else {
            if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
            throw NSError(domain: "CC360Framer", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Expected a two-track 360 file, found \(videos.count) video track(s)."])
        }
        do {
            let frameDuration = try await videos[0].load(.minFrameDuration)
            let size = try await videos[0].load(.naturalSize)
            let comp = AVMutableComposition()
            let range = CMTimeRange(start: .zero, duration: duration)
            var videoIDs: [CMPersistentTrackID] = []
            for t in videos {
                let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try ct.insertTimeRange(range, of: t, at: .zero)
                videoIDs.append(ct.trackID)
            }
            var options: [AudioOption] = []
            for (i, t) in tracks.filter({ $0.mediaType == .audio }).enumerated() {
                let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try ct.insertTimeRange(range, of: t, at: .zero)
                let descs = try await t.load(.formatDescriptions)
                options.append(AudioOption(id: ct.trackID, label: describe(descs.first, index: i), enabled: i == 0))
            }
            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = StackCompositor.self
            vc.frameDuration = frameDuration.isValid && frameDuration.seconds > 0 ? frameDuration : CMTime(value: 1001, timescale: 30000)
            vc.renderSize = CGSize(width: size.width, height: size.height * 2)
            vc.instructions = [StackInstruction(timeRange: range, trackIDs: videoIDs)]
            return MediaSession(url: url, asset: asset, videoTracks: videos, duration: duration, composition: comp,
                                videoComposition: vc, audioOptions: options, tempDir: tempDir)
        } catch {
            if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
            throw error
        }
    }

    /// Volume 1 for the enabled audio tracks, 0 for the others.
    func audioMix(for options: [AudioOption]) -> AVAudioMix? {
        let mix = AVMutableAudioMix()
        mix.inputParameters = options.compactMap { opt in
            guard let track = composition.track(withTrackID: opt.id) else { return nil }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(opt.enabled ? 1 : 0, at: .zero)
            return p
        }
        return mix
    }

    /// Opens the container. AVFoundation rejects the `.360` extension, but it is plain MP4: first try the file directly
    /// with the MIME type forced to `video/mp4` (no temporary files); if that fails, open it through a temporary
    /// `.mp4` symlink in a unique directory. `CC360_FORCE_SYMLINK=1` skips the direct attempt.
    private static func loadAsset(_ url: URL) async throws -> (AVURLAsset, [AVAssetTrack], CMTime, URL?) {
        if url.pathExtension.lowercased() == "360" {
            if ProcessInfo.processInfo.environment["CC360_FORCE_SYMLINK"] == nil {
                let direct = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
                if let tracks = try? await direct.load(.tracks), tracks.contains(where: { $0.mediaType == .video }),
                   let duration = try? await direct.load(.duration) {
                    return (direct, tracks, duration, nil)
                }
            }
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("CC360Framer-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mp4")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
            let asset = AVURLAsset(url: link)
            do {
                let (tracks, duration) = try await asset.load(.tracks, .duration)
                return (asset, tracks, duration, dir)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
        }
        let asset = AVURLAsset(url: url)
        let (tracks, duration) = try await asset.load(.tracks, .duration)
        return (asset, tracks, duration, nil)
    }

    static func describe(_ desc: CMFormatDescription?, index: Int) -> String {
        guard let desc, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return "Audio \(index + 1)"
        }
        let ch = Int(asbd.mChannelsPerFrame)
        let kind: String
        switch ch {
        case 1: kind = "mono"
        case 2: kind = "stereo"
        case 4: kind = "4ch ambisonic"
        default: kind = "\(ch)ch"
        }
        let codec = asbd.mFormatID == kAudioFormatMPEG4AAC ? "AAC" : (asbd.mFormatID == kAudioFormatLinearPCM ? "PCM" : "audio")
        return "\(index + 1): \(codec) \(kind)"
    }
}
