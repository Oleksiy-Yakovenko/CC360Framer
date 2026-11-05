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
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    var sourcePixelBufferAttributes: [String: Any]? { Self.attrs }
    var requiredPixelBufferAttributesForRenderContext: [String: Any] { Self.attrs }

    private static let skipBlit = ProcessInfo.processInfo.environment["CC360_NOBLIT"] != nil
    private let device = MTLCreateSystemDefaultDevice()!
    private lazy var queue = device.makeCommandQueue()!
    private var cache: CVMetalTextureCache!

    override init() {
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func cancelAllPendingVideoCompositionRequests() {}

    /// Luma and chroma plane textures of a biplanar 4:2:0 buffer (the video's native format: no BGRA conversion).
    private func planes(_ pb: CVPixelBuffer) -> (cv: [CVMetalTexture], y: MTLTexture, c: MTLTexture)? {
        func plane(_ i: Int, _ format: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
            var cv: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(
                nil, cache, pb, nil, format, CVPixelBufferGetWidthOfPlane(pb, i), CVPixelBufferGetHeightOfPlane(pb, i), i, &cv) == kCVReturnSuccess,
                  let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
            return (cv, t)
        }
        guard let (cy, ty) = plane(0, .r8Unorm), let (cc, tc) = plane(1, .rg8Unorm) else { return nil }
        return ([cy, cc], ty, tc)
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? StackInstruction,
              let out = request.renderContext.newPixelBuffer(), let dst = planes(out),
              let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
            request.finish(with: NSError(domain: "CC360Framer", code: 1))
            return
        }
        var keep: [CVMetalTexture] = dst.cv
        var y = 0
        for id in instruction.trackIDs {
            guard let src = request.sourceFrame(byTrackID: id), let s = planes(src) else { continue }
            keep += s.cv
            let (w, h) = (s.y.width, s.y.height)
            if Self.skipBlit { y += h; continue }   // diagnostic control only (CC360_NOBLIT)
            blit.copy(from: s.y, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1), to: dst.y, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: y, z: 0))
            blit.copy(from: s.c, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: s.c.width, height: s.c.height, depth: 1), to: dst.c, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: y / 2, z: 0))
            y += h
        }
        blit.endEncoding()
        cb.addCompletedHandler { cb in
            _ = keep
            if Pacing.enabled { Pacing.gpu(cb.gpuEndTime - cb.gpuStartTime) }
            request.finish(withComposedVideoFrame: out)
        }
        cb.commit()
    }
}
