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

    /// `hostTime`: when the frame will be on screen (the display link's target), not "now".
    func next(at hostTime: CFTimeInterval) -> (CVPixelBuffer, Double)? {
        guard let output else { return nil }
        let t = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: t) else { return nil }
        // The frame's own timestamp, not the host clock: the stabilised camera must match the image on screen.
        var shown = CMTime.zero
        let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: &shown)
        if Pacing.enabled, pb != nil { Pacing.newFrame() }
        if debug, let pb {
            count += 1
            let now = CACurrentMediaTime()
            if now - lastReport >= 2 {
                print("frames: \(Double(count) / (now - lastReport)) fps, last \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb)) t=\(t.seconds)")
                fflush(stdout)
                count = 0; lastReport = now
            }
        }
        return pb.map { ($0, shown.isValid ? shown.seconds : t.seconds) }
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
    /// Which timeline the bottom bar and seekbar edit (not saved).
    @Published var activeTimeline: TimelineKind = .keyframes
    /// Cut regions (source time), per file in the project sidecar.
    @Published var cuts: [CutRegion] = [] { didSet { if cuts != oldValue { cutsChanged() } } }
    @Published var selectedCut: UUID?
    /// Preview playback skips the cut regions; per file in the project sidecar.
    @Published var previewWithCuts = false { didSet { if previewWithCuts != oldValue { cutsChanged() } } }
    struct CutSnapshot: Equatable { var cuts: [CutRegion]; var selected: UUID? }
    private(set) lazy var cutUndo = SnapshotUndo<CutSnapshot>(
        manager: undo.manager,
        capture: { [unowned self] in CutSnapshot(cuts: cuts, selected: selectedCut) },
        restore: { [unowned self] s in
            cuts = s.cuts
            selectedCut = s.selected
        })
    var cutDragStart: CutSnapshot?
    var cutObserver: Any?
    /// Keyframes and selection as one undoable unit.
    struct KeySnapshot: Equatable { var keys: [Keyframe]; var selected: UUID? }
    private(set) lazy var undo = SnapshotUndo<KeySnapshot>(
        capture: { [unowned self] in KeySnapshot(keys: keyframes, selected: selectedKey) },
        restore: { [unowned self] s in
            keyframes = s.keys
            selectedKey = s.selected
            keysEdited = true
            saveKeyframes()
        })
    /// Exposed to the window (see `AppDelegate.windowWillReturnUndoManager`) so Edit > Undo/Redo work.
    var undoManager: UndoManager { undo.manager }
    @Published var autoFollow = false
    @Published var analysisProgress: Double?
    @Published var exportProgress: Double?
    @Published var statusText: String?
    @Published var style: PathStyle = PathStyle(rawValue: UserDefaults.standard.string(forKey: "pathStyle") ?? "") ?? .follow {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: "pathStyle") }
    }
    @Published var stabilization: StabilizeMode = .smooth
    /// Export format, size and rate control. App-wide default in UserDefaults, per file in the project sidecar.
    @Published var exportSettings = ExportSettings.loadDefaults() {
        didSet {
            if showExportFrame { viewState.exportFrameAspect = exportSettings.aspectValue }
            guard exportSettings != oldValue, !loadingProject else { return }
            exportSettings.saveDefaults()
            saveProject()
        }
    }
    /// Replaces the fov of every keyframe (preview, export, batch) while enabled. Default in UserDefaults, per file in the project sidecar.
    @Published var globalFov = GlobalFov.loadDefaults() {
        didSet {
            viewState.fovLocked = globalFov.enabled
            guard globalFov != oldValue, !loadingProject else { return }
            globalFov.saveDefaults()
            saveProject()
        }
    }
    /// Preview only: outline the export aspect in the player (not saved).
    @Published var showExportFrame = false { didSet { viewState.exportFrameAspect = showExportFrame ? exportSettings.aspectValue : nil } }
    private var telemetry: Telemetry?
    /// Bitmaps and timing of the overlays (location card; captions later) shared by the preview and the export.
    private(set) var overlays = OverlayBundle.empty
    var onOverlays: ((OverlayBundle) -> Void)?
    @Published var overlayPlacement: OverlayPlacement = OverlayPlacement(rawValue: UserDefaults.standard.string(forKey: "overlayPlacement") ?? "") ?? .bottomLeft {
        didSet {
            if !loadingProject { UserDefaults.standard.set(overlayPlacement.rawValue, forKey: "overlayPlacement") }
            if overlayPlacement != oldValue, !restoringPlacement {
                let old = oldValue
                registerPlacementUndo(old)
            }
            rebuildOverlays()
            if overlayPlacement != oldValue { saveProject() }
        }
    }
    private var restoringPlacement = false

    /// Location card keyframes (source time, each with its own placement); per file in the project sidecar. Once there is
    /// at least one, only they decide when the card shows (see `LocationCards`).
    @Published var cardKeys: [LocationCardKey] = [] { didSet { if cardKeys != oldValue { cardsChanged() } } }
    @Published var selectedCardKey: UUID?
    /// The implicit card at t = 0 (used while there are no card keyframes); per file in the project sidecar.
    @Published var autoLocationCard = true { didSet { if autoLocationCard != oldValue { cardsChanged() } } }
    struct CardKeySnapshot: Equatable { var keys: [LocationCardKey]; var selected: UUID?; var auto: Bool }
    private(set) lazy var cardKeyUndo = SnapshotUndo<CardKeySnapshot>(
        manager: undo.manager,
        capture: { [unowned self] in CardKeySnapshot(keys: cardKeys, selected: selectedCardKey, auto: autoLocationCard) },
        restore: { [unowned self] s in
            cardKeys = s.keys
            selectedCardKey = s.selected
            autoLocationCard = s.auto
        })
    var cardKeyDragStart: CardKeySnapshot?

    /// Look of the location card; per file, saved in the project sidecar.
    @Published private(set) var cardStyle = LocationCardStyle()
    private var loadingProject = false
    var loadingProjectFlag: Bool { loadingProject }
    private var lastCardEdit: (name: String, at: Date)?
    private(set) lazy var cardUndo = SnapshotUndo<LocationCardStyle>(
        manager: undo.manager,
        capture: { [unowned self] in cardStyle },
        restore: { [unowned self] s in
            cardStyle = s
            rebuildOverlays()
            saveProject()
        })

    /// Changes the card style (undoable, saved, preview and export update). Repeated edits of the same control within a
    /// second (colour well drags, sliders) collapse into one undo step.
    func setCardStyle(_ new: LocationCardStyle, name: String = "Change Location Card") {
        guard new != cardStyle else { return }
        let before = cardStyle
        cardStyle = new
        rebuildOverlays()
        saveProject()
        let now = Date()
        if let last = lastCardEdit, last.name == name, now.timeIntervalSince(last.at) < 1 { lastCardEdit = (name, now); return }
        lastCardEdit = (name, now)
        cardUndo.register(before, name)
    }

    /// Rebuilds the overlay bitmaps and the plan and hands them to the preview (the export reads `overlays` when it starts).
    func rebuildOverlays() {
        guard !loadingProject else { return }
        let plan = OverlayPlan(hasPlace: place != nil, autoCard: autoLocationCard, autoPlacement: overlayPlacement, cardKeys: cardKeys)
        overlays = OverlayBundle.make(place: place, plan: plan, style: cardStyle)
        onOverlays?(overlays)
        objectWillChange.send()   // the timeline bar enables Add once a place is known
    }

    private func loadProject(for url: URL) {
        let proj = ProjectSidecar.load(for: url)
        loadingProject = true
        cardStyle = proj.locationStyle ?? LocationCardStyle()
        exportSettings = proj.exportSettings ?? ExportSettings.loadDefaults()
        globalFov = proj.globalFov ?? GlobalFov.loadDefaults()
        cuts = proj.cuts ?? []
        selectedCut = nil
        cardKeys = proj.locationCards ?? []
        selectedCardKey = nil
        autoLocationCard = proj.autoLocationCard ?? true
        previewWithCuts = proj.previewWithCuts ?? false
        restoringPlacement = true
        overlayPlacement = proj.locationPlacement
            ?? OverlayPlacement(rawValue: UserDefaults.standard.string(forKey: "overlayPlacement") ?? "") ?? .bottomLeft
        restoringPlacement = false
        loadingProject = false
        rebuildOverlays()
    }

    func saveProject() {
        guard !loadingProject, let sourceURL else { return }
        ProjectSidecar(locationStyle: cardStyle, locationPlacement: overlayPlacement, exportSettings: exportSettings, globalFov: globalFov,
                       cuts: cuts.isEmpty ? nil : cuts, previewWithCuts: previewWithCuts ? true : nil,
                       locationCards: cardKeys.isEmpty ? nil : cardKeys, autoLocationCard: autoLocationCard ? nil : false).save(for: sourceURL)
    }

    var selectedKeyframe: Keyframe? { selectedKey.flatMap { id in keyframes.first { $0.id == id } } }

    /// Applies Inspector edits to the selected keyframe (undoable). Invalid edits leave everything as it was.
    func editSelectedKey(_ values: KeyframeEdit.Values) {
        guard let id = selectedKey, let old = selectedKeyframe else { return }
        guard let new = KeyframeEdit.apply(keyframes, id: id, values, duration: duration) else {
            objectWillChange.send()   // let the fields snap back to the stored values
            return
        }
        guard new != keyframes else { return }
        undo.perform("Edit Keyframe") {
            keyframes = new
            keysEdited = true
            saveKeyframes()
        }
        if let moved = new.first(where: { $0.id == id }), moved.time != old.time { scrub(to: moved.time); endScrub(at: moved.time) }
    }

    private func registerPlacementUndo(_ old: OverlayPlacement) {
        undoManager.registerUndo(withTarget: self) { m in
            let current = m.overlayPlacement
            m.restoringPlacement = true
            m.overlayPlacement = old
            m.restoringPlacement = false
            m.registerPlacementUndo(current)
        }
        undoManager.setActionName("Change Location Card Placement")
    }
    private(set) var place: PlaceInfo?
    private var placeTask: Task<Void, Never>?
    private(set) var stabilizer: Stabilizer?
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
            let (asset, tracks, duration) = try await loadAsset(url)
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
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
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
            telemetry = Telemetry.load(url: url)
            loadProject(for: url)
            loadPlace(for: url)
            rebuildStabilizer()
            keyframes = loadKeyframes(for: url)
            undoManager.removeAllActions()
            observations = loadObservations(for: url)
            keysEdited = !keyframes.isEmpty
            selectedKey = nil
            autoFollow = !keyframes.isEmpty
            await player.seek(to: .zero)
            updateCutPreview()
            if ProcessInfo.processInfo.environment["CC360_DEBUG"] != nil {
                print("opened: \(options.map(\.label)), item status \(item.status.rawValue)"); fflush(stdout)
                if let secs = Pacing.seconds {
                    if ProcessInfo.processInfo.environment["CC360_NOPLAY"] == nil { togglePlay() }
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                        Pacing.report(); exit(0)
                    }
                } else if let out = ProcessInfo.processInfo.environment["CC360_BATCH"] {
                    Task { await runBatch(URL(fileURLWithPath: out)) }
                } else {
                    togglePlay()
                }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Looks up the place name for the first GPS fix (cached next to the video) and builds the title card.
    private func loadPlace(for url: URL) {
        placeTask?.cancel()
        place = nil
        rebuildOverlays()
        guard let fix = telemetry?.gps else { placeTask = nil; return }
        placeTask = Task { [weak self] in
            let info: PlaceInfo
            if let cached = PlaceInfo.cached(for: url, matching: fix) {
                info = cached.withAltitude(of: fix)
                if info != cached { info.save(for: url) }   // refresh caches written before altitude existed
            } else { info = await PlaceInfo.lookup(fix: fix, cacheFor: url) }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.place = info
            self.rebuildOverlays()
            if ProcessInfo.processInfo.environment["CC360_DEBUG"] != nil { print("location: \(info.lines.joined(separator: " | "))"); fflush(stdout) }
        }
    }

    /// Opens the container. AVFoundation rejects the `.360` extension, but it is plain MP4: first try the file directly
    /// with the MIME type forced to `video/mp4` (no temporary files); if that fails, open it through a temporary
    /// `.mp4` symlink in a per-model directory. `CC360_FORCE_SYMLINK=1` skips the direct attempt.
    private func loadAsset(_ url: URL) async throws -> (AVURLAsset, [AVAssetTrack], CMTime) {
        if url.pathExtension.lowercased() == "360" {
            if ProcessInfo.processInfo.environment["CC360_FORCE_SYMLINK"] == nil {
                let direct = AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
                if let tracks = try? await direct.load(.tracks), tracks.contains(where: { $0.mediaType == .video }),
                   let duration = try? await direct.load(.duration) {
                    removeTempDir()
                    return (direct, tracks, duration)
                }
            }
            let asset = AVURLAsset(url: try playableURL(url))
            let (tracks, duration) = try await asset.load(.tracks, .duration)
            return (asset, tracks, duration)
        }
        removeTempDir()
        let asset = AVURLAsset(url: url)
        let (tracks, duration) = try await asset.load(.tracks, .duration)
        return (asset, tracks, duration)
    }

    /// Symlink fallback; the directory is unique per model so several windows never share or delete each other's links.
    private func playableURL(_ url: URL) throws -> URL {
        removeTempDir()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CC360Framer-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let link = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        return link
    }

    private func removeTempDir() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    func cleanup() { removeTempDir() }

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
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
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
            skipCutIfNeeded()   // starting inside a cut with "Preview with cuts applied"

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
    private func loadKeyframes(for url: URL) -> [Keyframe] {
        guard let data = Sidecar.read(for: url, kind: "reframe") else { return [] }
        return (try? JSONDecoder().decode([Keyframe].self, from: data)) ?? []
    }

    private func loadObservations(for url: URL) -> [Observation] {
        guard let data = Sidecar.read(for: url, kind: "analysis") else { return [] }
        return (try? JSONDecoder().decode([Observation].self, from: data)) ?? []
    }

    private func saveObservations() {
        guard let sourceURL, let data = try? JSONEncoder().encode(observations) else { return }
        Sidecar.write(data, for: sourceURL, kind: "analysis")
    }

    private func saveKeyframes() {
        guard let sourceURL else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(keyframes) { Sidecar.write(data, for: sourceURL, kind: "reframe") }
    }

    /// Called every draw: while following, the view tracks the camera path at the playhead.
    func applyPath() {
        if autoFollow {
            let cur = (yaw: viewState.yaw, pitch: viewState.pitch, fov: viewState.fovDegrees)
            let cam = path.sample(at: player.currentTime().seconds, global: globalFov, fallback: cur)
            viewState.yaw = cam.yaw
            viewState.pitch = cam.pitch
            viewState.fovDegrees = cam.fov
        } else if globalFov.enabled {
            viewState.fovDegrees = globalFov.resolve(viewState.fovDegrees)
        }
    }

    /// Adds (or replaces) a keyframe at the playhead using the current view.
    func setKey() {
        guard item != nil else { return }
        undo.perform("Set Key") { setKeyUndoable() }
    }

    private func setKeyUndoable() {
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
        undo.perform("Delete Key") {
            keyframes.removeAll { $0.id == id }
            selectedKey = nil
            keysEdited = true
            saveKeyframes()
        }
    }

    func clearKeys() {
        undo.perform("Clear Keys") {
            keyframes = []
            selectedKey = nil
            autoFollow = false
            saveKeyframes()
        }
    }

    func analyze() {
        guard let asset = sourceAsset, analysisProgress == nil else { return }
        let tracks = sourceVideoTracks
        let flag = CancelFlag()
        job = flag
        analysisProgress = 0
        statusText = "Analysing…"
        let box = UncheckedBox((asset, tracks, stabilizer))
        Task.detached(priority: .utility) { [weak self] in
            do {
                let found = try Analyzer.run(asset: box.value.0, videoTracks: box.value.1, stabilizer: box.value.2, progress: { p in
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

    private func rebuildStabilizer() {
        guard let telemetry else {
            stabilizer = nil
            viewState.stabilizer = nil
            if stabilization != .off { statusText = "No orientation telemetry in this file: stabilisation unavailable." }
            return
        }
        stabilizer = Stabilizer(telemetry: telemetry, duration: duration, mode: stabilization)
        viewState.stabilizer = stabilizer
    }

    /// Switching stabilisation changes what the path is relative to, so regenerate it like a style change.
    func stabilizationChanged() {
        rebuildStabilizer()
        styleChanged()
    }

    /// Observations expressed in the stabilised virtual camera (the analyser stores body-frame directions).
    private func virtualObservations() -> [Observation] {
        guard let stabilizer else { return observations }
        func convert(_ c: Candidate, _ t: Double) -> Candidate {
            let v = stabilizer.toVirtual(yaw: c.yaw, pitch: c.pitch, at: t)
            return Candidate(yaw: v.yaw, pitch: v.pitch, score: c.score)
        }
        return observations.map { o in
            Observation(t: o.t, people: o.people.map { convert($0, o.t) }, salient: o.salient.map { convert($0, o.t) })
        }
    }

    /// Replaces the keyframes with a path generated from the stored observations in the chosen style.
    func buildPath() {
        let keys = style.keyframes(from: virtualObservations(), duration: duration, fov: 70)
        guard !keys.isEmpty else { statusText = "Nothing found to build a path from."; return }
        undo.perform("Build Path") {
            keyframes = keys
            selectedKey = nil
            keysEdited = false
            autoFollow = true
            saveKeyframes()
        }
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
        await placeTask?.value
        if ProcessInfo.processInfo.environment["CC360_STYLE"] == "scenery" { style = .scenery }
        if ProcessInfo.processInfo.environment["CC360_NO_ANALYSIS"] != nil {
            keyframes = []; autoFollow = false   // plain stabilised export of the default view
        } else if observations.isEmpty { analyze() } else { buildPath() }
        while analysisProgress != nil {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print(String(format: "analysis %.0f%% (%.0fs)", (analysisProgress ?? 1) * 100, Date().timeIntervalSince(started))); fflush(stdout)
        }
        print("analysis done: \(statusText ?? "?")"); fflush(stdout)
        for st in PathStyle.allCases {
            let keys = st.keyframes(from: virtualObservations(), duration: duration, fov: 70)
            print("style \(st.rawValue): \(keys.count) keyframes")
        }
        for k in keyframes.prefix(400) {
            print(String(format: "  t=%5.1f yaw=%5.0f° pitch=%4.0f° fov=%3.0f", k.time, Double(k.yaw) * 180 / .pi, Double(k.pitch) * 180 / .pi, k.fov))
        }
        let exportStart = Date()
        if let json = ProcessInfo.processInfo.environment["CC360_EXPORT_SETTINGS"], let s = try? JSONDecoder().decode(ExportSettings.self, from: Data(json.utf8)) {
            loadingProject = true   // a test override: do not save it as the default
            exportSettings = s
            loadingProject = false
        }
        if let v = ProcessInfo.processInfo.environment["CC360_GLOBAL_FOV"], let deg = Float(v) {
            loadingProject = true   // a test override: do not save it as the default
            globalFov = GlobalFov(enabled: true, degrees: deg)
            loadingProject = false
            print("global fov: \(globalFov.degrees)"); fflush(stdout)
        }
        let o = exportSettings.outputSize
        print("export settings: \(exportSettings.container.rawValue) \(exportSettings.codec.rawValue) \(o.width)x\(o.height)"); fflush(stdout)
        export(to: out)
        while exportProgress != nil {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            print(String(format: "export %.0f%% (%.0fs)", (exportProgress ?? 1) * 100, Date().timeIntervalSince(exportStart))); fflush(stdout)
        }
        print("export done: \(statusText ?? "?")"); fflush(stdout)
        exit(0)
    }

    func export(to url: URL) {
        let settings = exportSettings
        guard let comp = composition, let vc = videoComposition, exportProgress == nil else { return }
        let flag = CancelFlag()
        job = flag
        exportProgress = 0
        statusText = nil
        let audioIDs = audioOptions.filter(\.enabled).map(\.id)
        let mix = audioMix()
        let path = self.path
        let fallback = (yaw: viewState.yaw, pitch: viewState.pitch, fov: viewState.fovDegrees)
        let global = globalFov
        let box = UncheckedBox((comp, vc, mix, stabilizer))
        let pending = placeTask
        let map = timeMap(crossfade: settings.crossfade)
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                await pending?.value   // make sure the location lookup has finished
                let overlays = await MainActor.run { self?.overlays ?? .empty }
                try Exporter.run(overlays: overlays, composition: box.value.0, videoComposition: box.value.1, audioMix: box.value.2,
                                 audioTrackIDs: audioIDs, path: path, global: global, fallback: fallback, stabilizer: box.value.3, settings: settings, timeMap: map, to: url,
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
