import AVFoundation
import Metal
import CoreVideo

/// Instruction asking the compositor to stack the given source tracks vertically.
final class StackInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = false
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackIDs: [CMPersistentTrackID]

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID]) {
        self.timeRange = timeRange
        self.trackIDs = trackIDs
        requiredSourceTrackIDs = trackIDs.map { NSNumber(value: $0) }
        super.init()
    }
}

/// Custom compositor that copies both lens tracks into one tall frame (track 0 on top)
/// so a single AVPlayerItemVideoOutput can deliver both to the Metal view.
final class StackCompositor: NSObject, AVVideoCompositing {
    private static let attrs: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var sourcePixelBufferAttributes: [String: Any]? { Self.attrs }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { Self.attrs }

    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var cache: CVMetalTextureCache!

    override init() {
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    private func texture(_ pb: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
        var cv: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pb, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cv) == kCVReturnSuccess,
              let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
        return (cv, t)
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? StackInstruction,
              let out = request.renderContext.newPixelBuffer(),
              let (outCV, dst) = texture(out),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
            request.finish(with: NSError(domain: "CC360Framer", code: 1))
            return
        }
        var keep: [CVMetalTexture] = [outCV]
        var y = 0
        for id in instruction.trackIDs {
            guard let src = request.sourceFrame(byTrackID: id), let (cv, t) = texture(src) else { continue }
            keep.append(cv)
            blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: t.width, height: t.height, depth: 1),
                      to: dst, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: y, z: 0))
            y += t.height
        }
        blit.endEncoding()
        cb.addCompletedHandler { _ in
            _ = keep
            request.finish(withComposedVideoFrame: out)
        }
        cb.commit()
    }
}
