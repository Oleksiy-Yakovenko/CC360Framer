import AVFoundation

/// Processes one file for the batch, headless and independent of any `PlayerModel`: analysis (or the cached sidecar),
/// path building, then the export. Settings of the file (cuts, captions, location cards, global fov) come from its sidecars;
/// the export settings and path style come from the batch.
enum BatchJob {
    struct Options {
        var forceReanalyse = false
        var export = true
        var style: PathStyle = .follow
        var exportSettings = ExportSettings()
    }

    static let debug = ProcessInfo.processInfo.environment["CC360_DEBUG"] != nil

    private static func log(_ s: String) { if debug { print("batch: " + s); fflush(stdout) } }

    /// Raw detections converted into the stabilised virtual camera (the analyser stores body-frame directions).
    static func virtualObservations(_ obs: [Observation], stabilizer: Stabilizer?) -> [Observation] {
        guard let stabilizer else { return obs }
        func convert(_ c: Candidate, _ t: Double) -> Candidate {
            let v = stabilizer.toVirtual(yaw: c.yaw, pitch: c.pitch, at: t)
            return Candidate(yaw: v.yaw, pitch: v.pitch, score: c.score)
        }
        return obs.map { o in Observation(t: o.t, people: o.people.map { convert($0, o.t) }, salient: o.salient.map { convert($0, o.t) }) }
    }

    /// `output` is required when `options.export` is on. Reports state changes through `progress` (any thread).
    static func run(url: URL, options: Options, output: URL?, cancel: CancelFlag,
                    progress: @escaping @Sendable (BatchItem.State) -> Void) async throws {
        let session = try await MediaSession.open(url)
        defer { session.cleanup() }
        let duration = session.duration.seconds
        let telemetry = Telemetry.load(url: url)
        let stabilizer = telemetry.map { Stabilizer(telemetry: $0, duration: duration, mode: .smooth) }

        // Detections: cached sidecar unless forced.
        var observations: [Observation] = []
        if !options.forceReanalyse, let data = Sidecar.read(for: url, kind: "analysis") {
            observations = (try? JSONDecoder().decode([Observation].self, from: data)) ?? []
        }
        var existingKeys: [Keyframe] = []
        if let data = Sidecar.read(for: url, kind: "reframe") { existingKeys = (try? JSONDecoder().decode([Keyframe].self, from: data)) ?? [] }

        var analysed = false
        if observations.isEmpty {
            progress(.analysing(0))
            let box = UncheckedBox((session.asset, session.videoTracks, stabilizer))
            observations = try await Task.detached(priority: .utility) {
                try Analyzer.run(asset: box.value.0, videoTracks: box.value.1, duration: duration, stabilizer: box.value.2,
                                 progress: { progress(.analysing($0)) }, cancel: cancel)
            }.value
            analysed = true
            if let data = try? JSONEncoder().encode(observations) { Sidecar.write(data, for: url, kind: "analysis") }
            log("analysed \(url.lastPathComponent): \(observations.count) observations")
        }
        if cancel.isSet { throw CancellationError() }

        // Keyframes: keep the user's (existing sidecar) unless forced; build when there are none.
        progress(.building)
        var keys = existingKeys
        if options.forceReanalyse || keys.isEmpty {
            let built = options.style.keyframes(from: virtualObservations(observations, stabilizer: stabilizer), duration: duration, fov: 70)
            if !built.isEmpty {
                keys = built
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? enc.encode(keys) { Sidecar.write(data, for: url, kind: "reframe") }
            }
            log("path \(options.style.rawValue): \(built.count) keyframes\(analysed ? "" : " (cached analysis)")")
        } else {
            log("keeping \(keys.count) existing keyframes")
        }
        guard options.export else { return }
        guard let output else { throw Exporter.Failure(errorDescription: "No output file.") }

        // Per-file project settings.
        let project = ProjectSidecar.load(for: url)
        let settings = options.exportSettings
        let global = project.globalFov ?? GlobalFov.loadDefaults()
        let map = TimeMap(cuts: project.cuts ?? [], duration: duration, crossfade: settings.crossfade)
        let overlays = await overlayBundle(url: url, project: project, telemetry: telemetry)
        let audioIDs = session.audioOptions.filter(\.enabled).map(\.id)
        let mix = session.audioMix(for: session.audioOptions)
        let path = CameraPath(keys: keys)
        progress(.exporting(0))
        let box = UncheckedBox((session.composition, session.videoComposition, mix, stabilizer))
        try await Task.detached(priority: .userInitiated) {
            try Exporter.run(overlays: overlays, composition: box.value.0, videoComposition: box.value.1, audioMix: box.value.2,
                             audioTrackIDs: audioIDs, path: path, global: global, fallback: (yaw: 0, pitch: 0, fov: 70),
                             stabilizer: box.value.3, settings: settings, timeMap: map, to: output,
                             progress: { progress(.exporting($0)) }, cancel: cancel)
        }.value
        log("exported \(output.path)")
    }

    /// Location card and captions of the file, as in the interactive player.
    @MainActor
    private static func overlayBundle(url: URL, project: ProjectSidecar, telemetry: Telemetry?) async -> OverlayBundle {
        var place: PlaceInfo?
        if let fix = telemetry?.gps {
            place = await PlaceInfo.resolve(fix: fix, cacheFor: url)
        }
        let placement = project.locationPlacement
            ?? OverlayPlacement(rawValue: UserDefaults.standard.string(forKey: "overlayPlacement") ?? "") ?? .bottomLeft
        let captionStyle = project.captionStyle ?? CaptionStyle.loadDefaults()
        let plan = OverlayPlan(hasPlace: place != nil, showCard: project.showLocationCard ?? true, cardFields: project.locationFields ?? LocationCardFields(), autoCard: project.autoLocationCard ?? true, autoPlacement: placement,
                               cardKeys: project.locationCards ?? [], captions: project.captions ?? [], captionStyle: captionStyle)
        return OverlayBundle.make(place: place, plan: plan, style: project.locationStyle ?? LocationCardStyle(), captionCache: CaptionImageCache())
    }
}
