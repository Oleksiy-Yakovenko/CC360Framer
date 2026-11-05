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

/// A direction in the scene with a relevance score.
struct Candidate: Codable {
    var yaw: Float
    var pitch: Float
    var score: Float
}

/// Raw detections at one point in time; path styles decide what to do with them.
struct Observation: Codable {
    var t: Double
    var people: [Candidate]      // person detections, all views
    var salient: [Candidate]     // salient objects in the side views (no forward/back views)
}

/// Decodes both lens tracks at low resolution, projects eight views around the horizon for
/// every Nth frame, and records person detections plus salient objects on the sides.
enum Analyzer {
    struct Failure: LocalizedError { let errorDescription: String? }

    private static let viewCount = 8
    private static let viewFov: Float = 90
    private static let viewSize = 512

    /// `step`: analyse every Nth decoded frame (6 ≈ 5 Hz at 30 fps).
    static func run(asset: AVAsset, videoTracks: [AVAssetTrack], step: Int = 6,
                    progress: @escaping (Double) -> Void, cancel: CancelFlag) throws -> [Observation] {
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

        var observations: [Observation] = []
        var index = 0
        let duration = max(asset.duration.seconds, 0.001)
        while let a = outs[0].copyNextSampleBuffer(), let b = outs[1].copyNextSampleBuffer() {
            defer { index += 1 }
            if cancel.isSet { reader.cancelReading(); throw CancellationError() }
            guard index % step == 0,
                  let pa = CMSampleBufferGetImageBuffer(a), let pb = CMSampleBufferGetImageBuffer(b),
                  renderer.setStacked(pa, pb) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(a).seconds

            var obs = Observation(t: t, people: [], salient: [])
            for v in 0..<viewCount {
                let viewYaw = Float(v) * 2 * .pi / Float(viewCount)
                renderer.renderSync(to: viewTexture, yaw: viewYaw, pitch: 0, fov: viewFov)
                let handler = VNImageRequestHandler(cvPixelBuffer: viewBuffer, options: [:])
                let people = VNDetectHumanRectanglesRequest()
                // Views straight ahead (0) and behind (4) are covered by the forward shot and the rider.
                let sideView = v != 0 && v != viewCount / 2
                let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
                try? handler.perform(sideView ? [people, objects] : [people])
                for o in people.results ?? [] {
                    // People cut by the view edge are seen better in the neighbouring view.
                    let edge = min(o.boundingBox.minX, 1 - o.boundingBox.maxX)
                    let area = Float(o.boundingBox.width * o.boundingBox.height) * Float(o.confidence) * (edge < 0.02 ? 0.5 : 1)
                    obs.people.append(candidate(o.boundingBox, viewYaw: viewYaw, score: area))
                }
                for o in objects.results?.first?.salientObjects ?? [] {
                    // Prefer mid-sized objects: tiny ones are noise, frame-filling ones are just the surroundings.
                    let area = Float(o.boundingBox.width * o.boundingBox.height)
                    let edge = min(o.boundingBox.minX, 1 - o.boundingBox.maxX)
                    let score = Float(o.confidence) * min(area * 4, 1) * (area > 0.5 ? 0.3 : 1) * (edge < 0.02 ? 0.5 : 1)
                    obs.salient.append(candidate(o.boundingBox, viewYaw: viewYaw, score: score))
                }
            }
            observations.append(obs)
            progress(min(t / duration, 1))
        }
        if reader.status == .failed { throw reader.error ?? Failure(errorDescription: "Decoding failed.") }
        return observations
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

    private static func candidate(_ box: CGRect, viewYaw: Float, score: Float) -> Candidate {
        let d = direction(viewYaw: viewYaw, ndcX: Float(box.midX - 0.5) * 2, ndcY: Float(box.midY - 0.5) * 2)
        return Candidate(yaw: d.yaw, pitch: d.pitch, score: score)
    }
}
