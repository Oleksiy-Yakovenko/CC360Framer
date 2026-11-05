import AppKit
import MetalKit
import CoreVideo

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct U { float yaw; float pitch; float tanHalfFov; float aspect; float4 cfg; float mode; };
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
static float3 sampleStrip(texture2d<float> tex, sampler smp, float c, float y, float yOff) {
    c = clamp(c, 0.0, STRIP - 0.001);
    float py = (y + yOff) / (2.0 * TH);
    float x1 = c, x2 = c + 64.0, x3 = c + 128.0;
    if (c < 928.0) return tex.sample(smp, float2(x1 / TW, py)).rgb;
    if (c < 992.0) {
        float t = (c - 928.0) / 64.0;
        return mix(tex.sample(smp, float2(x1 / TW, py)).rgb, tex.sample(smp, float2(x2 / TW, py)).rgb, t);
    }
    if (c < 4768.0) return tex.sample(smp, float2(x2 / TW, py)).rgb;
    if (c < 4832.0) {
        float t = (c - 4768.0) / 64.0;
        return mix(tex.sample(smp, float2(x2 / TW, py)).rgb, tex.sample(smp, float2(x3 / TW, py)).rgb, t);
    }
    return tex.sample(smp, float2(x3 / TW, py)).rgb;
}

fragment float4 fs(VOut in [[stage_in]], constant U& u [[buffer(0)]],
                   texture2d<float> tex [[texture(0)]], sampler smp [[sampler(0)]]) {
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
    return float4(sampleStrip(tex, smp, c, y, yOff), 1.0);
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
    private(set) var texture: MTLTexture?
    /// Called each frame; returns a new frame when one is available.
    var frameProvider: (() -> CVPixelBuffer?)?
    /// Called at the start of every draw, e.g. to apply the camera path to the view state.
    var preDraw: (() -> Void)?
    private var stackTexture: MTLTexture?

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
        guard let (cvTex, t) = makeTexture(from: pb) else { return }
        recent.append(cvTex)
        if recent.count > 4 { recent.removeFirst() }   // keep in-flight frames alive
        texture = t
    }

    func setTexture(_ t: MTLTexture) { texture = t }

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
        texture = dst
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
        encode(into: pass, commandBuffer: cb, aspect: Float(target.width) / Float(target.height))
        cb.commit()
        cb.waitUntilCompleted()
    }

    func encode(into pass: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer, aspect: Float) {
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let texture {
            var u = Uniforms(yaw: state.yaw, pitch: state.pitch,
                             tanHalfFov: tan(state.fovDegrees * .pi / 360), aspect: aspect,
                             cfg: state.cfg, mode: state.mode)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        preDraw?()
        if let pb = frameProvider?() { setFrame(pb) }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
        let size = view.drawableSize
        encode(into: pass, commandBuffer: cb, aspect: Float(size.width / max(size.height, 1)))
        cb.present(drawable)
        cb.commit()
    }
}

/// MTKView with mouse look: drag to look around, scroll to zoom, double-click to reset.
final class LookView: MTKView {
    var state: ViewState!

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
