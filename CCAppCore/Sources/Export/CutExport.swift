import AVFoundation
import CoreVideo

/// Pieces of the export that apply cut regions (see `TimeMap` for the crossfade semantics).
enum CutExport {
    /// Audio for the output timeline: the kept segments of each enabled source track laid out back to back, overlapping
    /// by the dissolve length. Overlapping needs two composition tracks per source track (a track cannot overlap
    /// itself); segments alternate between them and get matching volume ramps (fade out / fade in).
    static func audio(from source: AVComposition, trackIDs: [CMPersistentTrackID], map: TimeMap) throws -> (AVMutableComposition, AVAudioMix, [AVAssetTrack]) {
        let comp = AVMutableComposition()
        let mix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []
        let scale: CMTimeScale = 48000
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: scale) }
        for id in trackIDs {
            guard let src = source.track(withTrackID: id) else { continue }
            let lanes = (0..<2).compactMap { _ in comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
            guard lanes.count == 2 else { continue }
            let lanePars = lanes.map { AVMutableAudioMixInputParameters(track: $0) }
            for (i, seg) in map.segments.enumerated() {
                let lane = i % 2
                try lanes[lane].insertTimeRange(CMTimeRange(start: t(seg.sourceStart), duration: t(seg.length)), of: src, at: t(seg.outputStart))
                if i > 0, map.fades[i - 1] > 0 {
                    lanePars[lane].setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: t(seg.outputStart), duration: t(map.fades[i - 1])))
                }
                if i < map.fades.count, map.fades[i] > 0 {
                    lanePars[lane].setVolumeRamp(fromStartVolume: 1, toEndVolume: 0, timeRange: CMTimeRange(start: t(seg.outputEnd - map.fades[i]), duration: t(map.fades[i])))
                    lanePars[lane].setVolume(1, at: t(seg.outputEnd))   // the lane is silent here; a later segment must not inherit 0
                }
            }
            params += lanePars
        }
        mix.inputParameters = params
        return (comp, mix, comp.tracks(withMediaType: .audio))
    }

    /// Hands out the decoded frame that is current at a given source time from one segment's reader.
    final class FrameFeed {
        private let reader: AVAssetReader
        private let output: AVAssetReaderVideoCompositionOutput
        private var current: CMSampleBuffer?
        private var next: CMSampleBuffer?
        private var finished = false

        init(composition: AVComposition, videoComposition: AVVideoComposition, segment: TimeMap.Segment, duration: Double) throws {
            reader = try AVAssetReader(asset: composition)
            let fd = max(videoComposition.frameDuration.seconds, 1.0 / 120)
            // Start a little early so a frame at or before the segment start exists whatever the frame grid is.
            let start = max(0, segment.sourceStart - 2 * fd)
            let end = min(duration, segment.sourceEnd + fd)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000), end: CMTime(seconds: end, preferredTimescale: 60000))
            output = AVAssetReaderVideoCompositionOutput(
                videoTracks: composition.tracks(withMediaType: .video),
                videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                kCVPixelBufferMetalCompatibilityKey as String: true])
            output.videoComposition = videoComposition
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? Exporter.Failure(errorDescription: "Cannot start reading.") }
        }

        private func pull() -> CMSampleBuffer? {
            if finished { return nil }
            if let sb = output.copyNextSampleBuffer() { return sb }
            finished = true
            return nil
        }

        /// The newest frame whose time is at most `time` (+ `slack`); the first frame if none is that early.
        func frame(at time: Double, slack: Double) -> CVPixelBuffer? {
            if current == nil { current = pull() }
            while true {
                if next == nil { next = pull() }
                guard let n = next, CMSampleBufferGetPresentationTimeStamp(n).seconds <= time + slack else { break }
                current = n
                next = nil
            }
            return current.flatMap { CMSampleBufferGetImageBuffer($0) }
        }

        func cancel() { reader.cancelReading() }
    }

    /// `base = base * (1 - mix) + other * mix` for two BGRA buffers of the same size.
    static func blend(_ base: CVPixelBuffer, with other: CVPixelBuffer, mix: Double) {
        CVPixelBufferLockBaseAddress(base, [])
        CVPixelBufferLockBaseAddress(other, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(base, []); CVPixelBufferUnlockBaseAddress(other, .readOnly) }
        guard let a = CVPixelBufferGetBaseAddress(base), let b = CVPixelBufferGetBaseAddress(other),
              CVPixelBufferGetHeight(base) == CVPixelBufferGetHeight(other) else { return }
        let w = min(CVPixelBufferGetWidth(base), CVPixelBufferGetWidth(other)) * 4
        let h = CVPixelBufferGetHeight(base)
        let (ra, rb) = (CVPixelBufferGetBytesPerRow(base), CVPixelBufferGetBytesPerRow(other))
        let m = UInt32((max(0, min(1, mix)) * 256).rounded())
        for y in 0..<h {
            let pa = a.advanced(by: y * ra).assumingMemoryBound(to: UInt8.self)
            let pb = b.advanced(by: y * rb).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { pa[x] = UInt8((UInt32(pa[x]) * (256 - m) + UInt32(pb[x]) * m) >> 8) }
        }
    }
}
