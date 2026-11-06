import AppKit
import MetalKit
import CoreVideo

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U { float yaw; float pitch; float tanHalfFov; float aspect; float4 cfg; float mode; float yuv; float3 right; float3 up; float3 forward; };
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

fragment float4 fs(VOut in [[stage_in]], constant U& u [[buffer(0)]],
                   texture2d<float> tex [[texture(0)]], texture2d<float> texC [[texture(1)]], sampler smp [[sampler(0)]]) {
    float3 d;
    if (u.mode < 0.5) {
        d = normalize(float3(in.ndc.x * u.aspect * u.tanHalfFov, in.ndc.y * u.tanHalfFov, 1.0));
        float cp = cos(u.pitch), sp = sin(u.pitch);
        d = float3(d.x, d.y * cp + d.z * sp, -d.y * sp + d.z * cp);
        float cy = cos(u.yaw), sy = sin(u.yaw);
        d = float3(d.x * cy + d.z * sy, d.y, -d.x * sy + d.z * cy);
    } else {
        float lon = in.ndc.x * PI;
        float lat = in.ndc.y * PI * 0.5;
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
    return float4(sampleStrip(u, tex, texC, smp, c, y, yOff), 1.0);
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
    private var overlayTexture: MTLTexture?

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

    func setFrame(_ pb: CVPixelBuffer) {
        if CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            func plane(_ i: Int, _ f: MTLPixelFormat) -> (CVMetalTexture, MTLTexture)? {
                var cv: CVMetalTexture?
                guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, f, CVPixelBufferGetWidthOfPlane(pb, i),
                                                                CVPixelBufferGetHeightOfPlane(pb, i), i, &cv) == kCVReturnSuccess,
                      let cv, let t = CVMetalTextureGetTexture(cv) else { return nil }
                return (cv, t)
            }
            guard let (cy, ty) = plane(0, .r8Unorm), let (cc, tc) = plane(1, .rg8Unorm) else { return }
            recent += [cy, cc]
            if recent.count > 8 { recent.removeFirst(2) }   // keep in-flight frames alive
            texture = ty; chroma = tc
            return
        }
        guard let (cvTex, t) = makeTexture(from: pb) else { return }
        recent.append(cvTex)
        if recent.count > 4 { recent.removeFirst() }
        texture = t; chroma = nil
    }

    /// Title card (premultiplied BGRA, e.g. from `LocationOverlay.image`) shown over the first seconds of the video; nil removes it.
    func setOverlay(_ image: CGImage?) {
        guard let image else { overlayTexture = nil; return }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        guard let t = device.makeTexture(descriptor: d) else { return }
        t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        overlayTexture = t
    }

    private func drawOverlay(_ enc: MTLRenderCommandEncoder, targetWidth: Float, targetHeight: Float) {
        guard let tex = overlayTexture else { return }
        let alpha = LocationOverlay.alpha(at: state.frameTime)
        guard alpha > 0 else { return }
        // Card height is a fixed share of the short side; shrink if it would not fit the width.
        let short = min(targetWidth, targetHeight)
        var h = short * 0.4
        var w = h * Float(tex.width) / Float(tex.height)
        if w > targetWidth * 0.9 { w = targetWidth * 0.9; h = w * Float(tex.height) / Float(tex.width) }
        let margin = short * 0.04
        let ndcW = 2 * w / targetWidth, ndcH = 2 * h / targetHeight
        let mx = 2 * margin / targetWidth, my = 2 * margin / targetHeight
        let a = state.overlayPlacement.anchor
        let x0 = a.x < 0 ? -1 + mx : a.x > 0 ? 1 - mx - ndcW : -ndcW / 2
        let y0 = a.y < 0 ? -1 + my : a.y > 0 ? 1 - my - ndcH : -ndcH / 2
        var u: [Float] = [x0, y0, x0 + ndcW, y0 + ndcH, alpha, 0, 0, 0]
        enc.setRenderPipelineState(overlayPipeline)
        enc.setVertexBytes(&u, length: u.count * 4, index: 0)
        enc.setFragmentBytes(&u, length: u.count * 4, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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
        if let texture {
            let b = state.stabilizer?.basis(at: state.frameTime) ?? .identity
            var u = Uniforms(yaw: state.yaw, pitch: state.pitch,
                             tanHalfFov: tan(state.fovDegrees * .pi / 360), aspect: aspect,
                             cfg: state.cfg, mode: state.mode, yuv: chroma == nil ? 0 : 1,
                             right: SIMD4(b.right, 0), up: SIMD4(b.up, 0), forward: SIMD4(b.forward, 0))
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentTexture(chroma ?? texture, index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        drawOverlay(enc, targetWidth: Float(size.width), targetHeight: Float(size.height))
        if showGuide, let ea = state.exportFrameAspect, size.height > 0 {
            let h = ExportFrame.halfExtent(previewAspect: Double(size.width / size.height), exportAspect: ea)
            var g: [Float] = [Float(h.x), Float(h.y), Float(size.width), Float(size.height)]
            enc.setRenderPipelineState(guidePipeline)
            enc.setFragmentBytes(&g, length: g.count * 4, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let began = CACurrentMediaTime()
        var drawableWaited = 0.0
        defer { if Pacing.enabled { Pacing.timing(drawableWait: drawableWaited, body: CACurrentMediaTime() - began - drawableWaited) } }
        preDraw?()
        if let (pb, time) = frameProvider?(targetHostTime > 0 ? targetHostTime : CACurrentMediaTime()) { setFrame(pb); state.frameTime = time }
        let waitStart = CACurrentMediaTime()
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        drawableWaited = CACurrentMediaTime() - waitStart
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        let size = view.drawableSize
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
        state.onUserLook?()
        // Sensitivity scales with zoom so the scene follows the cursor.
        let perPixel = state.fovDegrees * .pi / 180 / Float(max(bounds.height, 1))
        state.yaw -= Float(event.deltaX) * perPixel
        state.pitch += Float(event.deltaY) * perPixel
        state.pitch = max(-1.55, min(1.55, state.pitch))
        state.yaw = atan2(sin(state.yaw), cos(state.yaw))
    }

    override func scrollWheel(with event: NSEvent) {
        state.onUserLook?()
        let dy = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.2 : 1.5)
        state.fovDegrees = max(20, min(140, state.fovDegrees - dy))
    }

    override func magnify(with event: NSEvent) {
        state.onUserLook?()
        state.fovDegrees = max(20, min(140, state.fovDegrees * (1 - Float(event.magnification))))
    }
}
