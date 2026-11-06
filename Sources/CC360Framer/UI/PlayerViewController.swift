import AppKit
import MetalKit

/// The preview: Metal view with mouse look, plus the error banner.
final class PlayerViewController: ModelViewController {
    private var renderer: Renderer?
    private(set) var lookView: LookView!
    private var detectionsOverlay: DetectionsOverlayView?
    private let errorLabel = NSTextField(wrappingLabelWithString: "")

    override func loadView() {
        let container = NSView()
        let device = MTLCreateSystemDefaultDevice()!
        let look = LookView(frame: .zero, device: device)
        look.state = model.viewState
        look.colorPixelFormat = .bgra8Unorm
        look.preferredFramesPerSecond = 60
        look.framebufferOnly = true
        let renderer = try! Renderer(device: device, state: model.viewState, pixelFormat: look.colorPixelFormat)
        renderer.frameProvider = { [frames = model.frames] host in frames.next(at: host) }
        renderer.incomingSource = model.frames
        renderer.preDraw = { [weak model] in MainActor.assumeIsolated { model?.applyPath() } }
        model.onOverlays = { [weak renderer] in renderer?.setOverlays($0) }
        model.onOverlays?(model.overlays)
        renderer.onOverlayTarget = { [weak model] in model?.setOverlayTarget(short: $0) }
        look.delegate = renderer
        self.renderer = renderer
        lookView = look
        Kit.pin(look, to: container)
        let overlay = DetectionsOverlayView()
        overlay.model = model
        Kit.pin(overlay, to: container)
        detectionsOverlay = overlay
        renderer.onFrame = { [weak overlay] in MainActor.assumeIsolated { overlay?.frameChanged() } }

        errorLabel.drawsBackground = true
        errorLabel.backgroundColor = NSColor.systemRed.withAlphaComponent(0.8)
        errorLabel.textColor = .white
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
        ])
        view = container
    }

    override func refresh() {
        errorLabel.stringValue = model.errorText ?? ""
        errorLabel.isHidden = model.errorText == nil
        detectionsOverlay?.frameChanged()
    }
}

/// Preview-only outlines of the detected subjects, drawn over the Metal view. Never takes mouse events, so mouse look still works.
final class DetectionsOverlayView: NSView {
    weak var model: PlayerModel?
    private var shapes: [Detections.Shape] = []
    private var lastKey: [Double] = []

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Recomputes the shapes for the frame being shown and redraws only when something changed.
    func frameChanged() {
        guard let model, bounds.width > 0, bounds.height > 0 else { return }
        let state = model.viewState
        var next: [Detections.Shape] = []
        var key: [Double] = [Double(bounds.width), Double(bounds.height)]
        if model.showDetections, let o = Detections.observation(in: model.observations, at: state.frameTime) {
            let aspect = bounds.width / bounds.height
            let cam = Detections.Camera(
                yaw: state.yaw, pitch: state.pitch,
                tanHalfFov: Detections.previewTanHalfFov(fovDegrees: state.fovDegrees, previewAspect: Double(aspect), exportAspect: state.exportFrameAspect),
                aspect: Float(aspect), basis: state.stabilizer?.basis(at: state.frameTime) ?? .identity)
            next = Detections.shapes(for: o, camera: cam)
            key += [o.t, Double(cam.yaw), Double(cam.pitch), Double(cam.tanHalfFov), Double(cam.basis.forward.x), Double(cam.basis.forward.y), Double(cam.basis.forward.z), Double(cam.basis.right.x), Double(cam.basis.right.z)]
        }
        guard key != lastKey || next.isEmpty != shapes.isEmpty else { return }
        lastKey = key
        shapes = next
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !shapes.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setLineWidth(2)
        ctx.setLineJoin(.round)
        func screen(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: (CGFloat(p.x) + 1) / 2 * bounds.width, y: (CGFloat(p.y) + 1) / 2 * bounds.height)
        }
        for s in shapes {
            let color = s.kind == .person ? NSColor.systemGreen : NSColor.systemYellow
            ctx.setStrokeColor(color.cgColor)
            if s.isPoint {
                let c = screen(s.points[0])
                ctx.move(to: CGPoint(x: c.x - 8, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 8, y: c.y))
                ctx.move(to: CGPoint(x: c.x, y: c.y - 8)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 8))
            } else {
                ctx.addLines(between: s.points.map(screen))
                ctx.closePath()
            }
            ctx.strokePath()
        }
    }
}
