import AVFoundation
import Vision
import Metal

/// Thread-safe cancel flag shared between the UI and a background job.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Finds the subject to follow. Decodes both lens tracks at low resolution, projects eight
/// views around the horizon for every Nth frame, runs Vision person detection on each, and
/// picks one subject per sample (large and close to the previous target wins).
enum Analyzer {
    struct Failure: LocalizedError { let errorDescription: String? }

    private static let viewCount = 8
    private static let viewFov: Float = 90
    private static let viewSize = 512

    /// `step`: analyse every Nth decoded frame (6 ≈ 5 Hz at 30 fps).
    static func run(asset: AVAsset, videoTracks: [AVAssetTrack], step: Int = 6,
                    progress: @escaping (Double) -> Void, cancel: CancelFlag) throws -> [Sample] {
        guard videoTracks.count == 2, let device = MTLCreateSystemDefaultDevice() else {
            throw Failure(errorDescription: "Analysis needs a two-track 360 file.")
        }
        let renderer = try Renderer(device: device, state: ViewState(), pixelFormat: .bgra8Unorm)
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Layout.trackWidth / 4,
            kCVPixelBufferHeightKey as String: Layout.trackHeight / 4,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        let outs = videoTracks.map { AVAssetReaderTrackOutput(track: $0, outputSettings: settings) }
        outs.forEach { $0.alwaysCopiesSampleData = false; reader.add($0) }
        guard reader.startReading() else { throw reader.error ?? Failure(errorDescription: "Cannot read video.") }

        // Reusable render target for the projected views (IOSurface so Vision can read it directly).
        var viewBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, viewSize, viewSize, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ] as CFDictionary, &viewBuffer)
        guard let viewBuffer, let (viewCV, viewTexture) = renderer.makeTexture(from: viewBuffer) else {
            throw Failure(errorDescription: "Cannot allocate analysis buffers.")
        }
        _ = viewCV

        var samples: [Sample] = []
        var previous: (yaw: Float, pitch: Float)?
        var index = 0
        let duration = max(asset.duration.seconds, 0.001)
        while let a = outs[0].copyNextSampleBuffer(), let b = outs[1].copyNextSampleBuffer() {
            defer { index += 1 }
            if cancel.isSet { reader.cancelReading(); throw CancellationError() }
            guard index % step == 0,
                  let pa = CMSampleBufferGetImageBuffer(a), let pb = CMSampleBufferGetImageBuffer(b),
                  renderer.setStacked(pa, pb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(a).seconds

            var candidates: [(yaw: Float, pitch: Float, score: Float)] = []
            for v in 0..<viewCount {
                let viewYaw = Float(v) * 2 * .pi / Float(viewCount)
                renderer.renderSync(to: viewTexture, yaw: viewYaw, pitch: 0, fov: viewFov)
                let request = VNDetectHumanRectanglesRequest()
                try? VNImageRequestHandler(cvPixelBuffer: viewBuffer, options: [:]).perform([request])
                for o in request.results ?? [] {
                    let box = o.boundingBox   // normalised, origin bottom-left
                    let dir = direction(viewYaw: viewYaw, ndcX: Float(box.midX - 0.5) * 2, ndcY: Float(box.midY - 0.5) * 2)
                    // People cut by the view edge are seen better in the neighbouring view.
                    let edge = min(box.minX, 1 - box.maxX)
                    let area = Float(box.width * box.height) * Float(o.confidence) * (edge < 0.02 ? 0.5 : 1)
                    candidates.append((dir.yaw, dir.pitch, area))
                }
            }
            if let best = pick(candidates, previous: previous) {
                previous = (best.yaw, best.pitch)
                samples.append(Sample(t: t, yaw: best.yaw, pitch: best.pitch, weight: best.score))
            }
            progress(min(t / duration, 1))
        }
        if reader.status == .failed { throw reader.error ?? Failure(errorDescription: "Decoding failed.") }
        return samples
    }

    /// Direction of a point in a rectilinear view (aspect 1) looking at `viewYaw`, pitch 0.
    private static func direction(viewYaw: Float, ndcX: Float, ndcY: Float) -> (yaw: Float, pitch: Float) {
        let th = tan(viewFov * .pi / 360)
        let n = (ndcX * th * ndcX * th + ndcY * th * ndcY * th + 1).squareRoot()
        let d = SIMD3<Float>(ndcX * th / n, ndcY * th / n, 1 / n)
        let x = d.x * cos(viewYaw) + d.z * sin(viewYaw)
        let z = -d.x * sin(viewYaw) + d.z * cos(viewYaw)
        return (atan2(x, z), asin(max(-1, min(1, d.y))))
    }

    private static func pick(_ c: [(yaw: Float, pitch: Float, score: Float)],
                             previous: (yaw: Float, pitch: Float)?) -> (yaw: Float, pitch: Float, score: Float)? {
        c.max { weight($0, previous) < weight($1, previous) }
    }

    private static func weight(_ c: (yaw: Float, pitch: Float, score: Float), _ prev: (yaw: Float, pitch: Float)?) -> Float {
        guard let prev else { return c.score }
        let dist = abs(wrapAngle(c.yaw - prev.yaw)) + abs(c.pitch - prev.pitch)
        let sigma: Float = 40 * .pi / 180
        return c.score * (1 + 2 * exp(-dist * dist / (2 * sigma * sigma)))
    }
}
