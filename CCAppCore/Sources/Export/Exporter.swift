import AVFoundation
import Metal

/// Renders the camera path into a flat video: both lens tracks are decoded through the stacking
/// compositor, reprojected with the same Metal shader as the preview, and encoded as HEVC or H.264 (see `ExportSettings`).
enum Exporter {
    struct Failure: LocalizedError { let errorDescription: String? }

    /// Blocking; call from a background thread.
    static func run(overlays: OverlayBundle, composition: AVMutableComposition, videoComposition: AVVideoComposition,
                    audioMix: AVAudioMix?, audioTrackIDs: [CMPersistentTrackID],
                    path: CameraPath, global: GlobalFov, fallback: (yaw: Float, pitch: Float, fov: Float),
                    stabilizer: Stabilizer?, settings: ExportSettings, timeMap: TimeMap? = nil, to url: URL,
                    progress: @escaping @Sendable (Double) -> Void, cancel: CancelFlag) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(errorDescription: "No Metal device.") }
        try? FileManager.default.removeItem(at: url)
        // With cuts the video comes from one reader per kept segment (see `CutExport`) and the audio from its own composition.
        let cutMap = timeMap?.hasCuts == true ? timeMap : nil
        if let cutMap, cutMap.segments.isEmpty { throw Failure(errorDescription: "Everything is cut: nothing left to export.") }
        let duration = max(cutMap?.outputDuration ?? composition.duration.seconds, 0.001)
        nonisolated(unsafe) let state = ViewState()
        state.stabilizer = stabilizer
        nonisolated(unsafe) let renderer = try Renderer(device: device, state: state, pixelFormat: .bgra8Unorm)
        renderer.setOverlays(overlays)

        nonisolated(unsafe) let reader = try AVAssetReader(asset: composition)
        nonisolated(unsafe) let vout = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            kCVPixelBufferMetalCompatibilityKey as String: true])
        vout.videoComposition = videoComposition
        vout.alwaysCopiesSampleData = false
        if cutMap == nil { reader.add(vout) }

        var audioReader = reader
        var cutAudio: AVMutableComposition?
        var audioTracks: [AVAssetTrack] = audioTrackIDs.compactMap { composition.track(withTrackID: $0) }
        var mixToUse = audioMix
        if let cutMap, !audioTracks.isEmpty {
            let (comp, mix, tracks) = try CutExport.audio(from: composition, trackIDs: audioTrackIDs, map: cutMap)
            cutAudio = comp; mixToUse = mix; audioTracks = tracks
            audioReader = try AVAssetReader(asset: comp)
        }
        nonisolated(unsafe) var aout: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
            o.audioMix = mixToUse
            audioReader.add(o)
            aout = o
        }
        _ = cutAudio   // keep the audio composition alive while reading

        nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: url, fileType: settings.container.fileType)
        let size = settings.outputSize
        nonisolated(unsafe) let vin = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoOutputSettings)
        vin.expectsMediaDataInRealTime = false
        nonisolated(unsafe) let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(vin)
        nonisolated(unsafe) var ain: AVAssetWriterInput?
        if aout != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: ExportSettings.audioBitRate])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            ain = i
        }

        guard writer.startWriting() else { throw writer.error ?? Failure(errorDescription: "Cannot start writing.") }
        if cutMap == nil {
            guard reader.startReading() else { throw reader.error ?? Failure(errorDescription: "Cannot start reading.") }
        } else if aout != nil {
            guard audioReader.startReading() else { throw audioReader.error ?? Failure(errorDescription: "Cannot start reading audio.") }
        }
        writer.startSession(atSourceTime: .zero)

        // The AVFoundation/Metal objects below are not Sendable. Each is used only by the one dispatch queue that drains its
        // writer input (video, audio) once setup is done, and `group.wait()` below joins those queues before anything else touches them.
        nonisolated(unsafe) let sharedComposition = composition
        let group = DispatchGroup()
        nonisolated(unsafe) var failure: Error?
        let failLock = NSLock()
        @Sendable func fail(_ e: Error) { failLock.lock(); if failure == nil { failure = e }; failLock.unlock() }

        // Renders one source frame through the camera at `time` (source seconds) into `out`.
        @Sendable func render(_ src: CVPixelBuffer, at time: Double, into out: CVPixelBuffer) -> Bool {
            guard let (cv, target) = renderer.makeTexture(from: out) else { return false }
            renderer.setFrame(src)
            state.frameTime = time   // stabiliser and location card follow the SOURCE time
            let cam = path.sample(at: time, global: global, fallback: fallback)
            renderer.renderSync(to: target, yaw: cam.yaw, pitch: cam.pitch, fov: cam.fov)
            _ = cv
            return true
        }

        group.enter()
        if let cutMap {
            let fd = videoComposition.frameDuration
            let frameSeconds = max(fd.seconds, 1.0 / 240)
            let total = max(1, Int((cutMap.outputDuration / frameSeconds).rounded()))
            let sourceDuration = composition.duration.seconds
            nonisolated(unsafe) var feeds: [Int: CutExport.FrameFeed] = [:]
            nonisolated(unsafe) var index = 0
            vin.requestMediaDataWhenReady(on: DispatchQueue(label: "export.video")) {
                func finish() { feeds.values.forEach { $0.cancel() }; vin.markAsFinished(); group.leave() }
                while vin.isReadyForMoreMediaData {
                    if cancel.isSet { fail(CancellationError()); finish(); return }
                    if index >= total { finish(); return }
                    let pts = CMTimeMultiply(fd, multiplier: Int32(index))
                    guard let sample = cutMap.sample(atOutput: Double(index) * frameSeconds) else { finish(); return }
                    do {
                        for k in feeds.keys where k < sample.segment { feeds[k]?.cancel(); feeds[k] = nil }
                        func feed(_ i: Int) throws -> CutExport.FrameFeed {
                            if let f = feeds[i] { return f }
                            let f = try CutExport.FrameFeed(composition: sharedComposition, videoComposition: videoComposition, segment: cutMap.segments[i], duration: sourceDuration)
                            feeds[i] = f
                            return f
                        }
                        let slack = frameSeconds / 2
                        guard let src = try feed(sample.segment).frame(at: sample.from, slack: slack) else { fail(Failure(errorDescription: "Missing frame at \(sample.from) s.")); finish(); return }
                        var out: CVPixelBuffer?
                        guard let pool = adaptor.pixelBufferPool else { continue }
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                        guard let out, render(src, at: sample.from, into: out) else { fail(Failure(errorDescription: "Render buffer failed.")); finish(); return }
                        if let to = sample.to, sample.mix > 0 {
                            guard let src2 = try feed(sample.segment + 1).frame(at: to, slack: slack) else { fail(Failure(errorDescription: "Missing frame at \(to) s.")); finish(); return }
                            var out2: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out2)
                            guard let out2, render(src2, at: to, into: out2) else { fail(Failure(errorDescription: "Render buffer failed.")); finish(); return }
                            CutExport.blend(out, with: out2, mix: sample.mix)
                        }
                        if !adaptor.append(out, withPresentationTime: pts) { fail(writer.error ?? Failure(errorDescription: "Append failed.")); finish(); return }
                    } catch {
                        fail(error); finish(); return
                    }
                    index += 1
                    progress(min(Double(index) / Double(total), 1))
                }
            }
        } else {
        vin.requestMediaDataWhenReady(on: DispatchQueue(label: "export.video")) {
            while vin.isReadyForMoreMediaData {
                if cancel.isSet { fail(CancellationError()); vin.markAsFinished(); group.leave(); return }
                guard let sb = vout.copyNextSampleBuffer() else { vin.markAsFinished(); group.leave(); return }
                guard let src = CMSampleBufferGetImageBuffer(sb), let pool = adaptor.pixelBufferPool else { continue }
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                guard let out, render(src, at: pts.seconds, into: out) else { fail(Failure(errorDescription: "Render buffer failed.")); vin.markAsFinished(); group.leave(); return }
                if !adaptor.append(out, withPresentationTime: pts) { fail(writer.error ?? Failure(errorDescription: "Append failed.")); vin.markAsFinished(); group.leave(); return }
                progress(min(pts.seconds / duration, 1))
            }
        }
        }
        if let aoutSafe = aout, let ainSafe = ain {
            nonisolated(unsafe) let aout = aoutSafe
            nonisolated(unsafe) let ain = ainSafe
            group.enter()
            ain.requestMediaDataWhenReady(on: DispatchQueue(label: "export.audio")) {
                while ain.isReadyForMoreMediaData {
                    guard let sb = aout.copyNextSampleBuffer() else { ain.markAsFinished(); group.leave(); return }
                    if !ain.append(sb) { fail(writer.error ?? Failure(errorDescription: "Audio append failed.")); ain.markAsFinished(); group.leave(); return }
                }
            }
        }
        group.wait()

        if let failure {
            reader.cancelReading(); writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw failure
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? Failure(errorDescription: "Export failed.") }
    }
}
