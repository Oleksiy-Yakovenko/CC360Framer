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
    @Published var keyframes: [Keyframe] = [] { didSet { path = CameraPath(keys: keyframes) } }
    @Published var selectedKey: UUID?
    @Published var autoFollow = false
    @Published var analysisProgress: Double?
    @Published var exportProgress: Double?
    @Published var statusText: String?
    @Published var style: PathStyle = .follow
    /// Raw detections from the last analysis; lets the style change without re-analysing.
    @Published private(set) var observations: [Observation] = []
    /// True once the user edited keyframes by hand (or loaded them from disk); style changes then ask for an explicit rebuild.
    private var keysEdited = false
    private(set) var path = CameraPath(keys: [])
    private var sourceURL: URL?
    private var sourceAsset: AVURLAsset?
    private var sourceVideoTracks: [AVAssetTrack] = []
    private var videoComposition: AVVideoComposition?
    private var job: CancelFlag?

    let frames = FrameSource()
    let viewState = ViewState()
    private(set) var player = AVPlayer()
    fileprivate var item: AVPlayerItem?
    fileprivate var composition: AVMutableComposition?
    private var timeObserver: Any?
    private var endObserver: Any?
    fileprivate var scrubbing = false
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
            self.videoComposition = vc
            self.sourceURL = url
            self.sourceAsset = asset
            self.sourceVideoTracks = videos
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
            viewState.onUserLook = { [weak self] in
                MainActor.assumeIsolated { self?.autoFollow = false }
            }
            keyframes = loadKeyframes(for: url)
            observations = loadObservations(for: url)
            keysEdited = !keyframes.isEmpty
            selectedKey = nil
            autoFollow = !keyframes.isEmpty
            await player.seek(to: .zero)
            if ProcessInfo.processInfo.environment["CC360_DEBUG"] != nil {
                print("opened: \(options.map(\.label)), item status \(item.status.rawValue)"); fflush(stdout)
                if let out = ProcessInfo.processInfo.environment["CC360_BATCH"] {
                    Task { await runBatch(URL(fileURLWithPath: out)) }
                } else {
                    togglePlay()
                }
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

    fileprivate func audioMix() -> AVAudioMix? {
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


// MARK: - Camera path, analysis, export

extension PlayerModel {
    private func sidecar(for url: URL) -> URL { url.appendingPathExtension("reframe.json") }

    private func loadKeyframes(for url: URL) -> [Keyframe] {
        guard let data = try? Data(contentsOf: sidecar(for: url)) else { return [] }
        return (try? JSONDecoder().decode([Keyframe].self, from: data)) ?? []
    }

    private func analysisURL(for url: URL) -> URL { url.appendingPathExtension("analysis.json") }

    private func loadObservations(for url: URL) -> [Observation] {
        guard let data = try? Data(contentsOf: analysisURL(for: url)) else { return [] }
        return (try? JSONDecoder().decode([Observation].self, from: data)) ?? []
    }

    private func saveObservations() {
        guard let sourceURL, let data = try? JSONEncoder().encode(observations) else { return }
        try? data.write(to: analysisURL(for: sourceURL))
    }

    private func saveKeyframes() {
        guard let sourceURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(keyframes) { try? data.write(to: sidecar(for: sourceURL)) }
    }

    /// Called every draw: while following, the view tracks the camera path at the playhead.
    func applyPath() {
        guard autoFollow, let cam = path.sample(at: player.currentTime().seconds) else { return }
        viewState.yaw = cam.yaw
        viewState.pitch = cam.pitch
        viewState.fovDegrees = cam.fov
    }

    /// Adds (or replaces) a keyframe at the playhead using the current view.
    func setKey() {
        guard item != nil else { return }
        let k = Keyframe(time: position, yaw: viewState.yaw, pitch: viewState.pitch, fov: viewState.fovDegrees)
        var keys = keyframes
        if let i = keys.firstIndex(where: { abs($0.time - position) < 0.15 }) {
            keys[i] = Keyframe(id: keys[i].id, time: keys[i].time, yaw: k.yaw, pitch: k.pitch, fov: k.fov)
            selectedKey = keys[i].id
        } else {
            keys.append(k)
            selectedKey = k.id
        }
        keyframes = keys.sorted { $0.time < $1.time }
        autoFollow = true
        keysEdited = true
        saveKeyframes()
    }

    func select(_ key: Keyframe) {
        selectedKey = key.id
        position = key.time
        scrub(to: key.time)
        endScrub(at: key.time)
    }

    func deleteSelectedKey() {
        guard let id = selectedKey else { return }
        keyframes.removeAll { $0.id == id }
        selectedKey = nil
        keysEdited = true
        saveKeyframes()
    }

    func clearKeys() {
        keyframes = []
        selectedKey = nil
        autoFollow = false
        saveKeyframes()
    }

    func analyze() {
        guard let asset = sourceAsset, analysisProgress == nil else { return }
        let tracks = sourceVideoTracks
        let flag = CancelFlag()
        job = flag
        analysisProgress = 0
        statusText = "Analysing…"
        let box = UncheckedBox((asset, tracks))
        Task.detached(priority: .utility) { [weak self] in
            do {
                let found = try Analyzer.run(asset: box.value.0, videoTracks: box.value.1, progress: { p in
                    Task { @MainActor in self?.analysisProgress = p }
                }, cancel: flag)
                await MainActor.run {
                    guard let self else { return }
                    self.analysisProgress = nil
                    self.observations = found
                    self.saveObservations()
                    self.buildPath()
                }
            } catch {
                await MainActor.run {
                    self?.analysisProgress = nil
                    self?.statusText = error is CancellationError ? "Analysis cancelled." : error.localizedDescription
                }
            }
        }
    }

    /// Replaces the keyframes with a path generated from the stored observations in the chosen style.
    func buildPath() {
        let keys = style.keyframes(from: observations, duration: duration, fov: 90)
        guard !keys.isEmpty else { statusText = "Nothing found to build a path from."; return }
        keyframes = keys
        selectedKey = nil
        keysEdited = false
        autoFollow = true
        saveKeyframes()
        statusText = "\(style.rawValue): \(keys.count) keyframes."
    }

    /// Switching style regenerates the path straight away, unless that would discard manual edits.
    func styleChanged() {
        guard !observations.isEmpty else { return }
        if keysEdited {
            statusText = "Press Build path to apply \"\(style.rawValue)\" (replaces your keyframes)."
        } else {
            buildPath()
        }
    }

    func cancelJob() { job?.set() }

    /// Headless end-to-end run for testing: analyse, then export (CC360_BATCH=out.mp4).
    func runBatch(_ out: URL) async {
        let started = Date()
        if ProcessInfo.processInfo.environment["CC360_STYLE"] == "scenery" { style = .scenery }
        analyze()
        while analysisProgress != nil {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print(String(format: "analysis %.0f%% (%.0fs)", (analysisProgress ?? 1) * 100, Date().timeIntervalSince(started))); fflush(stdout)
        }
        print("analysis done: \(statusText ?? "?")"); fflush(stdout)
        for st in PathStyle.allCases {
            let keys = st.keyframes(from: observations, duration: duration, fov: 90)
            print("style \(st.rawValue): \(keys.count) keyframes")
        }
        for k in keyframes.prefix(40) {
            print(String(format: "  t=%5.1f yaw=%5.0f° pitch=%4.0f° fov=%3.0f", k.time, Double(k.yaw) * 180 / .pi, Double(k.pitch) * 180 / .pi, k.fov))
        }
        let exportStart = Date()
        export(preset: Exporter.Preset.all[0], to: out)
        while exportProgress != nil {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print(String(format: "export %.0f%% (%.0fs)", (exportProgress ?? 1) * 100, Date().timeIntervalSince(exportStart))); fflush(stdout)
        }
        print("export done: \(statusText ?? "?")"); fflush(stdout)
        exit(0)
    }

    func export(preset: Exporter.Preset, to url: URL) {
        guard let comp = composition, let vc = videoComposition, exportProgress == nil else { return }
        let flag = CancelFlag()
        job = flag
        exportProgress = 0
        statusText = "Exporting…"
        let audioIDs = audioOptions.filter(\.enabled).map(\.id)
        let mix = audioMix()
        let path = self.path
        let fallback = (yaw: viewState.yaw, pitch: viewState.pitch, fov: viewState.fovDegrees)
        let box = UncheckedBox((comp, vc, mix))
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try Exporter.run(composition: box.value.0, videoComposition: box.value.1, audioMix: box.value.2,
                                 audioTrackIDs: audioIDs, path: path, fallback: fallback, preset: preset, to: url,
                                 progress: { p in Task { @MainActor in self?.exportProgress = p } }, cancel: flag)
                await MainActor.run { self?.exportProgress = nil; self?.statusText = "Exported \(url.lastPathComponent)." }
            } catch {
                await MainActor.run {
                    self?.exportProgress = nil
                    self?.statusText = error is CancellationError ? "Export cancelled." : error.localizedDescription
                }
            }
        }
    }
}

/// Carries non-Sendable AVFoundation objects into a background task.
final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
