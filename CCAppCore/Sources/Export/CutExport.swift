import AVFoundation
import CoreVideo

/// Pieces of the export that apply cut regions (see `TimeMap` for the crossfade semantics).
enum CutExport {
    // The audio for the output timeline (kept segments of each enabled track, dissolve lanes) lives in `AudioExport`.

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
