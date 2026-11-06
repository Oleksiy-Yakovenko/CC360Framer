import AVFoundation
import Metal

/// Renders the camera path into a flat video: both lens tracks are decoded through the stacking
/// compositor, reprojected with the same Metal shader as the preview, and encoded as HEVC or H.264 (see `ExportSettings`).
enum Exporter {
    struct Failure: LocalizedError { let errorDescription: String? }

    /// Blocking; call from a background thread.
    static func run(overlay: CGImage?, placement: OverlayPlacement, composition: AVMutableComposition, videoComposition: AVVideoComposition,
                    audioMix: AVAudioMix?, audioTrackIDs: [CMPersistentTrackID],
                    path: CameraPath, global: GlobalFov, fallback: (yaw: Float, pitch: Float, fov: Float),
                    stabilizer: Stabilizer?, settings: ExportSettings, to url: URL,
                    progress: @escaping (Double) -> Void, cancel: CancelFlag) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(errorDescription: "No Metal device.") }
        try? FileManager.default.removeItem(at: url)
        let duration = max(composition.duration.seconds, 0.001)
        let state = ViewState()
        state.stabilizer = stabilizer
        state.overlayPlacement = placement
        let renderer = try Renderer(device: device, state: state, pixelFormat: .bgra8Unorm)
        renderer.setOverlay(overlay)

        let reader = try AVAssetReader(asset: composition)
        let vout = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                            kCVPixelBufferMetalCompatibilityKey as String: true])
        vout.videoComposition = videoComposition
        vout.alwaysCopiesSampleData = false
        reader.add(vout)

        let audioTracks = audioTrackIDs.compactMap { composition.track(withTrackID: $0) }
        var aout: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
            o.audioMix = audioMix
            reader.add(o)
            aout = o
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: settings.container.fileType)
        let size = settings.outputSize
        let vin = AVAssetWriterInput(mediaType: .video, outputSettings: settings.videoOutputSettings)
        vin.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vin, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        writer.add(vin)
        var ain: AVAssetWriterInput?
        if aout != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: ExportSettings.audioBitRate])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            ain = i
        }

        guard writer.startWriting() else { throw writer.error ?? Failure(errorDescription: "Cannot start writing.") }
        guard reader.startReading() else { throw reader.error ?? Failure(errorDescription: "Cannot start reading.") }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        var failure: Error?
        let failLock = NSLock()
        func fail(_ e: Error) { failLock.lock(); if failure == nil { failure = e }; failLock.unlock() }

        group.enter()
        vin.requestMediaDataWhenReady(on: DispatchQueue(label: "export.video")) {
            while vin.isReadyForMoreMediaData {
                if cancel.isSet { fail(CancellationError()); vin.markAsFinished(); group.leave(); return }
                guard let sb = vout.copyNextSampleBuffer() else { vin.markAsFinished(); group.leave(); return }
                guard let src = CMSampleBufferGetImageBuffer(sb), let pool = adaptor.pixelBufferPool else { continue }
                var out: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
                guard let out, let (cv, target) = renderer.makeTexture(from: out) else { fail(Failure(errorDescription: "Render buffer failed.")); vin.markAsFinished(); group.leave(); return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                renderer.setFrame(src)
                state.frameTime = pts.seconds
                let cam = path.sample(at: pts.seconds, global: global, fallback: fallback)
                renderer.renderSync(to: target, yaw: cam.yaw, pitch: cam.pitch, fov: cam.fov)
                _ = cv
                if !adaptor.append(out, withPresentationTime: pts) { fail(writer.error ?? Failure(errorDescription: "Append failed.")); vin.markAsFinished(); group.leave(); return }
                progress(min(pts.seconds / duration, 1))
            }
        }
        if let aout, let ain {
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
