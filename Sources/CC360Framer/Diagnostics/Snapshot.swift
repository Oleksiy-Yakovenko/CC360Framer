import AppKit
import MetalKit
import ImageIO
import UniformTypeIdentifiers

/// Headless check of the projection: `CC360Framer --snapshot stacked.png outPrefix [cfg0 cfg1 cfg2 cfg3]`
/// where stacked.png is the two lens tracks stacked vertically (5888x3840).
/// Writes outPrefix-equirect.png plus six rectilinear views.
enum Snapshot {
    static func run(args: [String]) -> Int32 {
        guard args.count >= 2, let device = MTLCreateSystemDefaultDevice() else {
            print("usage: --snapshot stacked.png outPrefix [cfg x4]"); return 1
        }
        let state = ViewState()
        if args.count >= 6 {
            state.cfg = SIMD4<Float>(args[2...5].map { Float($0) ?? 1 })
        }
        // Optional stabilisation for calibration: CC360_TELEMETRY=file.360 CC360_TIME=sec CC360_MODE=level|smooth CC360_AXES=-1,-1,1
        let env = ProcessInfo.processInfo.environment
        if let axes = env["CC360_AXES"]?.split(separator: ",").compactMap({ Float($0) }), axes.count == 3 {
            Stabilizer.sensorToRender = SIMD3(axes[0], axes[1], axes[2])
        }
        if let file = env["CC360_TELEMETRY"], let t = Telemetry.load(url: URL(fileURLWithPath: file)) {
            let mode: StabilizeMode = env["CC360_MODE"] == "level" ? .level : .smooth
            state.stabilizer = Stabilizer(telemetry: t, duration: Double(env["CC360_DURATION"] ?? "") ?? 153.92, mode: mode)
            state.frameTime = Double(env["CC360_TIME"] ?? "") ?? 0
        }
        do {
            let tex = try MTKTextureLoader(device: device).newTexture(
                URL: URL(fileURLWithPath: args[0]),
                options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])
            let r = try Renderer(device: device, state: state, pixelFormat: .bgra8Unorm)
            r.setTexture(tex)
            let views: [(String, Float, Float, Float)] = [
                ("front", 0, 0, 0), ("right", 90, 0, 0), ("back", 180, 0, 0), ("left", 270, 0, 0),
                ("up", 0, 89, 0), ("down", 0, -89, 0),
            ]
            // CC360_YAW=deg[,deg...] adds views at these yaws (level horizon, fov 70, in the stabilised camera when CC360_TELEMETRY is set).
            for deg in (env["CC360_YAW"] ?? "").split(separator: ",").compactMap({ Float($0) }) {
                state.yaw = deg * .pi / 180; state.pitch = 0
                try render(r, state, mode: 0, size: (800, 600), to: args[1] + String(format: "-yaw%.0f.png", deg))
            }
            try render(r, state, mode: 1, size: (1600, 800), to: args[1] + "-equirect.png")
            for (name, yaw, pitch, _) in views {
                state.yaw = yaw * .pi / 180; state.pitch = pitch * .pi / 180
                try render(r, state, mode: 0, size: (800, 600), to: args[1] + "-\(name).png")
            }
            return 0
        } catch { print("error: \(error)"); return 1 }
    }

    static func render(_ r: Renderer, _ state: ViewState, mode: Float, size: (Int, Int), to path: String) throws {
        state.mode = mode
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: size.0, height: size.1, mipmapped: false)
        d.usage = [.renderTarget]
        d.storageMode = .shared
        let target = r.device.makeTexture(descriptor: d)!
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let cb = r.queue.makeCommandBuffer()!
        r.encode(into: pass, commandBuffer: cb, aspect: Float(size.0) / Float(size.1), size: CGSize(width: size.0, height: size.1))
        cb.commit()
        cb.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: size.0 * size.1 * 4)
        target.getBytes(&bytes, bytesPerRow: size.0 * 4, from: MTLRegionMake2D(0, 0, size.0, size.1), mipmapLevel: 0)
        let ctx = CGContext(data: &bytes, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: size.0 * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
