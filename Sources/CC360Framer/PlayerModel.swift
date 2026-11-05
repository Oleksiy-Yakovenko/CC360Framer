import AVFoundation
import AppKit
import Combine

struct AudioOption: Identifiable {
    let id: CMPersistentTrackID      // track id inside the composition
    let label: String
    var enabled: Bool
}

/// Hands decoded frames from the player item to the renderer.
final class FrameSource {
    var output: AVPlayerItemVideoOutput?
    private let debug = ProcessInfo.processInfo.environment["CC360_DEBUG"] != nil
    private var count = 0
    private var lastReport = CACurrentMediaTime()

    func next() -> CVPixelBuffer? {
        guard let output else { return nil }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
        if debug, let pb {
            count += 1
            let now = CACurrentMediaTime()
            if now - lastReport >= 2 {
                print("frames: \(Double(count) / (now - lastReport)) fps, last \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) t=\(t.seconds)")
                fflush(stdout)
                count = 0; lastReport = now
            }
        }
        return pb
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    @Published var title = "Open a .360 file"
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var position: Double = 0
    @Published var audioOptions: [AudioOption] = []
    @Published var errorText: String?

    let frames = FrameSource()
    let viewState = ViewState()
    private(set) var player = AVPlayer()
    private var item: AVPlayerItem?
    private var composition: AVMutableComposition?
    private var timeObserver: Any?
    private var endObserver: Any?
    private var scrubbing = false
    private var tempDir: URL?

    func open(_ url: URL) async {
        do {
            errorText = nil
            player.pause()
            isPlaying = false
            // AVFoundation refuses the .360 extension but reads the container fine as .mp4.
            let playURL = try playableURL(url)
            let asset = AVURLAsset(url: playURL)
            let (tracks, duration) = try await asset.load(.tracks, .duration)
            let videos = tracks.filter { $0.mediaType == .video }
            guard videos.count == 2 else {
                throw NSError(domain: "CC360Framer", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Expected a two-track 360 file, found \(videos.count) video track(s)."])
            }
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
                options.append(AudioOption(id: ct.trackID, label: Self.describe(descs.first, index: i), enabled: i == 0))
            }

            let vc = AVMutableVideoComposition()
            vc.customVideoCompositorClass = StackCompositor.self
            vc.frameDuration = frameDuration.isValid && frameDuration.seconds > 0 ? frameDuration : CMTime(value: 1001, timescale: 30000)
            vc.renderSize = CGSize(width: size.width, height: size.height * 2)
            vc.instructions = [StackInstruction(timeRange: range, trackIDs: videoIDs)]

            let item = AVPlayerItem(asset: comp)
            item.videoComposition = vc
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
            item.add(output)

            self.composition = comp
            self.audioOptions = options
            item.audioMix = audioMix()
            self.item = item
            frames.output = output
            player.replaceCurrentItem(with: item)
            self.duration = duration.seconds
            self.position = 0
            self.title = url.lastPathComponent
            installObservers(item)
            viewState.reset()
            await player.seek(to: .zero)
            if ProcessInfo.processInfo.environment["CC360_DEBUG"] != nil {
                print("opened: \(options.map(\.label)), item status \(item.status.rawValue)"); fflush(stdout)
                togglePlay()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func playableURL(_ url: URL) throws -> URL {
        if url.pathExtension.lowercased() != "360" { return url }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CC360Framer-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let link = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mp4")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        return link
    }

    func cleanup() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private static func describe(_ desc: CMFormatDescription?, index: Int) -> String {
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

    private func audioMix() -> AVAudioMix? {
        guard let composition else { return nil }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioOptions.compactMap { opt in
            guard let track = composition.track(withTrackID: opt.id) else { return nil }
            let p = AVMutableAudioMixInputParameters(track: track)
            p.setVolume(opt.enabled ? 1 : 0, at: .zero)
            return p
        }
        return mix
    }

    func toggleAudio(_ id: CMPersistentTrackID) {
        guard let i = audioOptions.firstIndex(where: { $0.id == id }) else { return }
        audioOptions[i].enabled.toggle()
        item?.audioMix = audioMix()
    }

    private func installObservers(_ item: AVPlayerItem) {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.position = t.seconds
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isPlaying = false }
        }
    }

    func togglePlay() {
        guard item != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if position >= duration - 0.05 { player.seek(to: .zero); position = 0 }
            player.play()
            isPlaying = true
        }
    }

    func beginScrub() { scrubbing = true }

    func scrub(to seconds: Double) {
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.2, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.2, preferredTimescale: 600))
    }

    func endScrub(at seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.scrubbing = false }
        }
    }
}
