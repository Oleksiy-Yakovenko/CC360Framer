import AppKit
import MetalKit

/// The preview: Metal view with mouse look, plus the error banner.
final class PlayerViewController: ModelViewController {
    private var renderer: Renderer?
    private(set) var lookView: LookView!
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
    }
}
