import AppKit
import MetalKit
import CoreVideo

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U { float yaw; float pitch; float tanHalfFov; float aspect; float4 cfg; float mode; float yuv; float mixB; float3 right; float3 up; float3 forward; };
struct VOut { float4 pos [[position]]; float2 ndc; };

vertex VOut vs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0, 1);
    o.ndc = p * 2.0 - 1.0;
    return o;
}

constant float PI = 3.14159265358979;
constant float TW = 5888.0;
constant float TH = 1920.0;
constant float STRIP = 5760.0;

// Samples the continuous strip (0..5760 px) of one track. The strip is stored as tiles of
// 992 / 3904 / 992 px with 64 px of overlap at each seam; the overlaps are feathered.
static float3 rgbAt(constant U& u, texture2d<float> tex, texture2d<float> texC, sampler smp, float2 uv) {
    if (u.yuv < 0.5) return tex.sample(smp, uv).rgb;
    float y = tex.sample(smp, uv).r;
    float2 c = texC.sample(smp, uv).rg - 0.5;
    return saturate(float3(y + 1.5748 * c.y, y - 0.1873 * c.x - 0.4681 * c.y, y + 1.8556 * c.x));
}

static float3 sampleStrip(constant U& u, texture2d<float> tex, texture2d<float> texC, sampler smp, float c, float y, float yOff) {
    c = clamp(c, 0.0, STRIP - 0.001);
    float py = (y + yOff) / (2.0 * TH);
    float x1 = c, x2 = c + 64.0, x3 = c + 128.0;
    if (c < 928.0) return rgbAt(u, tex, texC, smp, float2(x1 / TW, py));
    if (c < 992.0) {
        float t = (c - 928.0) / 64.0;
        return mix(rgbAt(u, tex, texC, smp, float2(x1 / TW, py)), rgbAt(u, tex, texC, smp, float2(x2 / TW, py)), t);
    }
    if (c < 4768.0) return rgbAt(u, tex, texC, smp, float2(x2 / TW, py));
    if (c < 4832.0) {
        float t = (c - 4768.0) / 64.0;
        return mix(rgbAt(u, tex, texC, smp, float2(x2 / TW, py)), rgbAt(u, tex, texC, smp, float2(x3 / TW, py)), t);
    }
    return rgbAt(u, tex, texC, smp, float2(x3 / TW, py));
}

// Colour of one source frame seen through camera `u`.
static float3 shade(constant U& u, float2 ndcPos, texture2d<float> tex, texture2d<float> texC, sampler smp) {
    float3 d;
    if (u.mode < 0.5) {
        d = normalize(float3(ndcPos.x * u.aspect * u.tanHalfFov, ndcPos.y * u.tanHalfFov, 1.0));
        float cp = cos(u.pitch), sp = sin(u.pitch);
        d = float3(d.x, d.y * cp + d.z * sp, -d.y * sp + d.z * cp);
        float cy = cos(u.yaw), sy = sin(u.yaw);
        d = float3(d.x * cy + d.z * sy, d.y, -d.x * sy + d.z * cy);
    } else {
        float lon = ndcPos.x * PI;
        float lat = ndcPos.y * PI * 0.5;
        d = float3(sin(lon) * cos(lat), sin(lat), cos(lon) * cos(lat));
    }

    // Virtual (horizon-locked) camera -> camera body axes, which is what the video is stored in.
    d = normalize(u.right * d.x + u.up * d.y + u.forward * d.z);

    float3 a = abs(d);
    bool track0 = (a.x >= a.y && a.x >= a.z) || (a.z >= a.x && a.z >= a.y && d.z > 0.0);

    float c, v, yOff;
    if (track0) {
        // ring around Y: front = 0, right = +
        float th = atan2(d.x, d.z) * u.cfg.x;
        float r = length(d.xz);
        float thc = clamp(round(th / (0.5 * PI)), -1.0, 1.0) * 0.5 * PI;
        float dl = th - thc;
        v = (4.0 / PI) * atan(d.y / max(r * cos(dl), 1e-5)) * u.cfg.y;
        c = (th / (1.5 * PI) + 0.5) * STRIP;
        yOff = 0.0;
    } else {
        // ring around X: bottom -> back -> top
        float th = atan2(d.y, -d.z) * u.cfg.z;
        float r = length(d.yz);
        float thc = clamp(round(th / (0.5 * PI)), -1.0, 1.0) * 0.5 * PI;
        float dl = th - thc;
        v = (4.0 / PI) * atan(d.x / max(r * cos(dl), 1e-5)) * u.cfg.w;
        c = (th / (1.5 * PI) + 0.5) * STRIP;
        yOff = TH;
    }
    float y = clamp((0.5 - 0.5 * v) * TH, 0.5, TH - 0.5);
    return sampleStrip(u, tex, texC, smp, c, y, yOff);
}

// u2 / tex2 / texC2: the incoming frame of a preview dissolve (own camera and stabiliser basis, rendered at its own
// source time); u.mixB is its weight, 0 outside a dissolve (then it is never sampled).
fragment float4 fs(VOut in [[stage_in]], constant U& u [[buffer(0)]], constant U& u2 [[buffer(1)]],
                   texture2d<float> tex [[texture(0)]], texture2d<float> texC [[texture(1)]],
                   texture2d<float> tex2 [[texture(2)]], texture2d<float> texC2 [[texture(3)]], sampler smp [[sampler(0)]]) {
    float3 a = shade(u, in.ndc, tex, texC, smp);
    if (u.mixB > 0.0) a = mix(a, shade(u2, in.ndc, tex2, texC2, smp), clamp(u.mixB, 0.0, 1.0));
    return float4(a, 1.0);
}
"""

private let overlayShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct OU { float4 rect; float alpha; };
struct OOut { float4 pos [[position]]; float2 uv; };
vertex OOut ovs(uint vid [[vertex_id]], constant OU& u [[buffer(0)]]) {
    float2 p = float2(vid & 1, vid >> 1);
    OOut o;
    o.pos = float4(mix(u.rect.xy, u.rect.zw, p), 0, 1);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
fragment float4 ofs(OOut in [[stage_in]], constant OU& u [[buffer(0)]], texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.uv) * u.alpha;   // premultiplied
}
"""

/// Preview guide: dims everything outside the export frame and outlines it. `r` = half extents (ndc) and target size in px.
private let guideShaderSource = """
#include <metal_stdlib>
using namespace metal;
struct GU { float4 r; };
struct GOut { float4 pos [[position]]; float2 ndc; };
vertex GOut gvs(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    GOut o;
    o.pos = float4(p * 2.0 - 1.0, 0, 1);
    o.ndc = p * 2.0 - 1.0;
    return o;
}
fragment float4 gfs(GOut in [[stage_in]], constant GU& u [[buffer(0)]]) {
    float2 d = (abs(in.ndc) - u.r.xy) * u.r.zw * 0.5;   // pixels beyond the frame edge (negative inside)
    float m = max(d.x, d.y);
    if (m > 0.0) return float4(0, 0, 0, 0.55);          // premultiplied black at 55 %
    if (m > -1.5) return float4(0.9, 0.9, 0.9, 0.9);    // thin outline just inside the edge
    return float4(0);
}
"""

/// Draws the projected view of a stacked 5888x3840 BGRA frame.
final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let state: ViewState
    private var cache: CVMetalTextureCache!
    private var recent: [CVMetalTexture] = []
    private(set) var texture: MTLTexture?          // BGRA image, or the luma plane of a YCbCr frame
    private var chroma: MTLTexture?                // CbCr plane when the frame is YCbCr
    /// Called each frame; returns a new frame when one is available.
    var frameProvider: ((CFTimeInterval) -> (CVPixelBuffer, Double)?)?
    /// Host time the frame being drawn will be shown at (set by the display link).
    var targetHostTime: CFTimeInterval = 0
    /// Called at the start of every draw, e.g. to apply the camera path to the view state.
    var preDraw: (() -> Void)?
    private var stackTexture: MTLTexture?
    private let overlayPipeline: MTLRenderPipelineState
    private let guidePipeline: MTLRenderPipelineState
    /// Overlay bitmaps by key plus the plan deciding what to draw at a time; guarded by a lock (set from the UI, read when drawing).
    private var overlayTextures: [String: (image: CGImage, texture: MTLTexture)] = [:]
    private var overlayPlan = OverlayPlan.empty
    private var overlayBuiltShort = 1080
    /// Preview: called (on the main queue, debounced) with the short side in pixels the overlays should be rasterised for,
    /// when it differs from what was last asked for; until the new bitmaps arrive the old ones are drawn scaled.
    var onOverlayTarget: ((Int) -> Void)?
    private var requestedShort = 0
    private var pendingShort = 0
    private var targetDebounce: DispatchWorkItem?
    static let targetDebounceSeconds = 0.15
    private let overlayLock = NSLock()
    /// Preview dissolve: the incoming frame (second texture set), its source time and weight. Only `draw` sets these; the
    /// export and snapshots never do, so their `mixB` stays 0 and the second set is never sampled.
    var incomingSource: FrameSource?
    private var textureB: MTLTexture?
    private var chromaB: MTLTexture?
    private var recentB: [CVMetalTexture] = []
    private var incomingGeneration = -1
    private(set) var incomingTime = 0.0
    private var mixB: Float = 0

    init(device: MTLDevice, state: ViewState, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        self.state = state
        queue = device.makeCommandQueue()!
        let lib = try device.makeLibrary(source: shaderSource, options: nil)
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: "vs")
        d.fragmentFunction = lib.makeFunction(name: "fs")
        d.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: d)
        let ol = try device.makeLibrary(source: overlayShaderSource, options: nil)
        let od = MTLRenderPipelineDescriptor()
        od.vertexFunction = ol.makeFunction(name: "ovs")
        od.fragmentFunction = ol.makeFunction(name: "ofs")
        let ca = od.colorAttachments[0]!
        ca.pixelFormat = pixelFormat
        ca.isBlendingEnabled = true
        ca.sourceRGBBlendFactor = .one; ca.sourceAlphaBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha; ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        overlayPipeline = try device.makeRenderPipelineState(descriptor: od)
        let gl = try device.makeLibrary(source: guideShaderSource, options: nil)
        let gd = MTLRenderPipelineDescriptor()
        gd.vertexFunction = gl.makeFunction(name: "gvs")
        gd.fragmentFunction = gl.makeFunction(name: "gfs")
        gd.colorAttachments[0].pixelFormat = pixelFormat
        gd.colorAttachments[0].isBlendingEnabled = true
        gd.colorAttachments[0].sourceRGBBlendFactor = .one; gd.colorAttachments[0].sourceAlphaBlendFactor = .one
        gd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha; gd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guidePipeline = try device.makeRenderPipelineState(descriptor: gd)
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear; s.magFilter = .linear
        s.sAddressMode = .clampToEdge; s.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: s)!
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// Metal texture view of a BGRA pixel buffer. Keep the returned CVMetalTexture alive while the GPU uses it.
    func makeTexture(from pb: CVPixelBuffer) -> (CVMetalTexture, MTLTexture)? {
        var cvTex: CVMetalTexture?
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let t = CVMetalTextureGetTexture(cvTex) else { return nil }
        return (cvTex, t)
    }

    /// Metal textures for a frame: luma + CbCr for a YCbCr buffer, else one BGRA texture. `keep` must stay alive while the GPU uses them.
    private func planes(of pb: CVPixelBuffer) -> (keep: [CVMetalTexture], y: MTLTexture, chroma: MTLTexture?)? {
        if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            func plane(_ i: Int, _ f: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
                var cv: CVMetalTexture?
                guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, f, CVPixelBufferGetWidthOfPlane(pb, i),
                                                                CVPixelBufferGetHeightOfPlane(pb, i), i, &cv) == kCVReturnSuccess,
                      let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
                return (cv, t)
            }
            guard let (cy, ty) = plane(0, .r8Unorm), let (cc, tc) = plane(1, .rg8Unorm) else { return nil }
            return ([cy, cc], ty, tc)
        }
        guard let (cvTex, t) = makeTexture(from: pb) else { return nil }
        return ([cvTex], t, nil)
    }

    func setFrame(_ pb: CVPixelBuffer) {
        guard let p = planes(of: pb) else { return }
        recent += p.keep
        if recent.count > 4 * p.keep.count { recent.removeFirst(p.keep.count) }   // keep in-flight frames alive
        texture = p.y; chroma = p.chroma
    }

    private func setIncomingFrame(_ pb: CVPixelBuffer) {
        guard let p = planes(of: pb) else { return }
        recentB += p.keep
        if recentB.count > 4 * p.keep.count { recentB.removeFirst(p.keep.count) }
        textureB = p.y; chromaB = p.chroma
    }

    private func clearIncoming() { textureB = nil; chromaB = nil; recentB = [] }

    /// The incoming player has become the main one: its latest frame is now the current picture.
    private func promoteIncoming(frameTimeSetter: (Double) -> Void) {
        if let tb = textureB {
            texture = tb; chroma = chromaB; recent = recentB
            frameTimeSetter(incomingTime)
        }
        clearIncoming()
    }

    /// Overlay bitmaps (premultiplied BGRA, keyed as the plan refers to them) and the plan; textures of unchanged images are reused.
    func setOverlays(_ bundle: OverlayBundle) {
        overlayLock.lock(); defer { overlayLock.unlock() }
        var textures: [String: (image: CGImage, texture: MTLTexture)] = [:]
        for (key, image) in bundle.images {
            if let old = overlayTextures[key], old.image === image { textures[key] = old; continue }
            if let t = makeOverlayTexture(image) { textures[key] = (image, t) }
        }
        overlayTextures = textures
        overlayPlan = bundle.plan
        overlayBuiltShort = bundle.targetShort
    }

    private func makeOverlayTexture(_ image: CGImage) -> MTLTexture? {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        return t
    }

    /// Composites every overlay that is active at the frame's (source) time, in plan order, over the picture.
    private func drawOverlay(_ enc: MTLRenderCommandEncoder, at time: Double, targetWidth: Float, targetHeight: Float, frame: (x: Float, y: Float, width: Float, height: Float)) {
        overlayLock.lock()
        let plan = overlayPlan, textures = overlayTextures, built = overlayBuiltShort
        overlayLock.unlock()
        for d in plan.draws(at: time, builtShort: built) {
            guard let tex = textures[d.key]?.texture else { continue }
            let r = OverlayLayout.rect(texWidth: tex.width, texHeight: tex.height, targetWidth: targetWidth, targetHeight: targetHeight, frame: frame,
                                       placement: d.placement, size: d.size)
            var u: [Float] = [r.x0, r.y0, r.x1, r.y1, d.alpha, 0, 0, 0]
            enc.setRenderPipelineState(overlayPipeline)
            enc.setVertexBytes(&u, length: u.count * 4, index: 0)
            enc.setFragmentBytes(&u, length: u.count * 4, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    func setTexture(_ t: MTLTexture) { texture = t; chroma = nil }

    /// Stacks the two lens frames (any matching size) into one texture and makes it current.
    func setStacked(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool {
        guard let (ca, ta) = makeTexture(from: a), let (cb2, tb) = makeTexture(from: b) else { return false }
        let w = ta.width, h = ta.height
        if stackTexture?.width != w || stackTexture?.height != h * 2 {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h * 2, mipmapped: false)
            d.usage = [.shaderRead]
            stackTexture = device.makeTexture(descriptor: d)
        }
        guard let dst = stackTexture, let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return false }
        for (i, t) in [ta, tb].enumerated() {
            blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1), to: dst, destinationSlice: 0,
                      destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: i * h, z: 0))
        }
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (ca, cb2)
        texture = dst; chroma = nil
        return true
    }

    /// Renders the current texture into `target` and waits for completion.
    func renderSync(to target: MTLTexture, yaw: Float, pitch: Float, fov: Float) {
        state.yaw = yaw; state.pitch = pitch; state.fovDegrees = fov; state.mode = 0
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let cb = queue.makeCommandBuffer() else { return }
        encode(into: pass, commandBuffer: cb, aspect: Float(target.width) / Float(target.height), size: CGSize(width: target.width, height: target.height))
        cb.commit()
        cb.waitUntilCompleted()
    }

    /// `showGuide` is for the on-screen preview only; renderSync (export, snapshots) never draws it.
    func encode(into pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, aspect: Float, size: CGSize, showGuide: Bool = false) {
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Guide on (preview only): render so the guide rectangle is exactly the exported field of view; overlays are laid out inside it.
        let guideAspect = showGuide && size.height > 0 ? state.exportFrameAspect : nil
        var fovScale: Float = 1
        var frame = (x: Float(0), y: Float(0), width: Float(size.width), height: Float(size.height))
        if let ea = guideAspect {
            fovScale = Float(ExportFrame.previewFovScale(previewAspect: Double(size.width / size.height), exportAspect: ea))
            let r = ExportFrame.pixelRect(width: Double(size.width), height: Double(size.height), exportAspect: ea)
            frame = (Float(r.x), Float(r.y), Float(r.width), Float(r.height))
        }
        var overlayTime = state.frameTime
        if let texture {
            let b = state.stabilizer?.basis(at: state.frameTime) ?? .identity
            var u = Uniforms(yaw: state.yaw, pitch: state.pitch,
                             tanHalfFov: tan(state.fovDegrees * .pi / 360) * fovScale, aspect: aspect,
                             cfg: state.cfg, mode: state.mode, yuv: chroma == nil ? 0 : 1,
                             right: SIMD4(b.right, 0), up: SIMD4(b.up, 0), forward: SIMD4(b.forward, 0))
            var u2 = u
            var texB = texture, chromaTex = chroma ?? texture
            if mixB > 0, let tb = textureB {
                // The incoming frame is rendered at ITS source time: camera path and stabiliser basis of that time.
                let cam = incomingSource?.incomingCamera?(incomingTime) ?? (yaw: state.yaw, pitch: state.pitch, fov: state.fovDegrees)
                let bb = state.stabilizer?.basis(at: incomingTime) ?? .identity
                u2 = Uniforms(yaw: cam.yaw, pitch: cam.pitch, tanHalfFov: tan(cam.fov * .pi / 360) * fovScale, aspect: aspect,
                              cfg: state.cfg, mode: state.mode, yuv: chromaB == nil ? 0 : 1,
                              right: SIMD4(bb.right, 0), up: SIMD4(bb.up, 0), forward: SIMD4(bb.forward, 0))
                u.mixB = mixB
                texB = tb; chromaTex = chromaB ?? tb
                if mixB >= 0.5 { overlayTime = incomingTime }   // overlays follow the outgoing frame until the cut point, then the incoming
            }
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentBytes(&u2, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentTexture(chroma ?? texture, index: 1)
            enc.setFragmentTexture(texB, index: 2)
            enc.setFragmentTexture(chromaTex, index: 3)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        drawOverlay(enc, at: overlayTime, targetWidth: Float(size.width), targetHeight: Float(size.height), frame: frame)
        if let ea = guideAspect {
            let h = ExportFrame.halfExtent(previewAspect: Double(size.width / size.height), exportAspect: ea)
            var g: [Float] = [Float(h.x), Float(h.y), Float(size.width), Float(size.height)]
            enc.setRenderPipelineState(guidePipeline)
            enc.setFragmentBytes(&g, length: g.count * 4, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Size the overlays are drawn into in the preview: the export-frame guide when it is on, else the whole drawable.
    private func overlayFrameSize(of size: CGSize) -> CGSize {
        guard let ea = state.exportFrameAspect, size.width > 0, size.height > 0 else { return size }
        let r = ExportFrame.pixelRect(width: Double(size.width), height: Double(size.height), exportAspect: ea)
        return CGSize(width: r.width, height: r.height)
    }

    /// Asks (debounced) for overlay bitmaps matching the preview's drawable size, so live resizing does not re-rasterise per frame.
    private func noteOverlayTarget(_ size: CGSize) {
        let short = OverlayScale.short(width: size.width, height: size.height)
        guard short != pendingShort else { return }
        pendingShort = short
        targetDebounce?.cancel()
        guard short != requestedShort else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pendingShort == short else { return }
            self.requestedShort = short
            self.onOverlayTarget?(short)
        }
        targetDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.targetDebounceSeconds, execute: work)
    }

    func draw(in view: MTKView) {
        let began = CACurrentMediaTime()
        var drawableWaited = 0.0
        defer { if Pacing.enabled { Pacing.timing(drawableWait: drawableWaited, body: CACurrentMediaTime() - began - drawableWaited) } }
        preDraw?()
        let host = targetHostTime > 0 ? targetHostTime : CACurrentMediaTime()
        if let src = incomingSource, src.takePromote() { promoteIncoming { self.state.frameTime = $0 } }
        if let (pb, time) = frameProvider?(host) { setFrame(pb); state.frameTime = time }
        mixB = 0
        if let src = incomingSource {
            let inc = src.incoming(at: host, outgoingTime: state.frameTime)
            if inc.generation != incomingGeneration { incomingGeneration = inc.generation; clearIncoming() }
            if let (pb, t) = inc.frame { setIncomingFrame(pb); incomingTime = t }
            if inc.active, textureB != nil { mixB = Float(inc.mix) }
        }
        let waitStart = CACurrentMediaTime()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        drawableWaited = CACurrentMediaTime() - waitStart
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        let size = view.drawableSize
        noteOverlayTarget(overlayFrameSize(of: size))
        encode(into: pass, commandBuffer: cb, aspect: Float(size.width / max(size.height, 1)), size: size, showGuide: true)
        cb.present(drawable)
        if Pacing.enabled {
            Pacing.drew()
            let pts = state.frameTime
            drawable.addPresentedHandler { Pacing.presented(at: $0.presentedTime, pts: pts) }
        }
        cb.commit()
    }
}

/// MTKView with mouse look: drag to look around, scroll to zoom, double-click to reset.
final class LookView: MTKView {
    var state: ViewState!
    private var link: CADisplayLink?

    /// Drawing is driven by the display link rather than MTKView's own timer: the video frame is chosen for the
    /// upcoming vsync, which keeps 30 fps video on a 60 Hz display evenly paced.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        isPaused = true
        enableSetNeedsDisplay = false
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func tick(_ l: CADisplayLink) {
        (delegate as? Renderer)?.targetHostTime = l.targetTimestamp
        draw()
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { state.reset() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard UserLook.dragCounts(deltaX: Double(event.deltaX), deltaY: Double(event.deltaY)) else { return }
        state.onUserLook?()
        // Sensitivity scales with zoom so the scene follows the cursor.
        var fov = Double(state.fovDegrees)
        if let ea = state.exportFrameAspect, bounds.height > 0 {   // the guide changes the fov the preview is drawn with
            fov = ExportFrame.previewFovDegrees(fov: fov, previewAspect: Double(bounds.width / bounds.height), exportAspect: ea)
        }
        let perPixel = Float(fov) * .pi / 180 / Float(max(bounds.height, 1))
        state.yaw -= Float(event.deltaX) * perPixel
        state.pitch += Float(event.deltaY) * perPixel
        state.pitch = max(-1.55, min(1.55, state.pitch))
        state.yaw = atan2(sin(state.yaw), cos(state.yaw))
    }

    override func scrollWheel(with event: NSEvent) {
        guard !state.fovLocked else { return }
        guard UserLook.scrollCounts(deltaY: Double(event.scrollingDeltaY), inMomentum: !event.momentumPhase.isEmpty) else { return }
        state.onUserLook?()
        let dy = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.2 : 1.5)
        state.fovDegrees = max(20, min(140, state.fovDegrees - dy))
    }

    override func magnify(with event: NSEvent) {
        guard !state.fovLocked else { return }
        guard UserLook.magnifyCounts(magnification: Double(event.magnification)) else { return }
        state.onUserLook?()
        state.fovDegrees = max(20, min(140, state.fovDegrees * (1 - Float(event.magnification))))
    }
}
