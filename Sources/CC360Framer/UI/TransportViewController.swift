import AVFoundation
import AppKit

/// NSSlider that tells its owner when a drag starts and ends (the tracking loop blocks inside `mouseDown`).
final class ScrubSlider: NSSlider {
    var onBegin: (() -> Void)?
    var onEnd: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBegin?()
        super.mouseDown(with: event)
        onEnd?()
    }
}

/// Keyframe markers under the seekbar; click one to select it and jump there.
final class KeyTicksView: NSView {
    var keys: [Keyframe] = []
    var selected: UUID?
    var duration: Double = 0
    var onSelect: ((Keyframe) -> Void)?
    private let inset: CGFloat = 8   // slider thumb radius

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 12) }

    private func x(_ key: Keyframe) -> CGFloat {
        inset + max(bounds.width - inset * 2, 1) * CGFloat(key.time / max(duration, 0.1))
    }

    override func draw(_ dirtyRect: NSRect) {
        for key in keys {
            let isSel = key.id == selected
            let r: CGFloat = isSel ? 5 : 3.5
            let c = CGPoint(x: x(key), y: bounds.midY)
            let path = NSBezierPath()
            path.move(to: CGPoint(x: c.x, y: c.y - r))
            path.line(to: CGPoint(x: c.x + r, y: c.y))
            path.line(to: CGPoint(x: c.x, y: c.y + r))
            path.line(to: CGPoint(x: c.x - r, y: c.y))
            path.close()
            (isSel ? NSColor.controlAccentColor : NSColor.systemOrange).setFill()
            path.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = keys.min(by: { abs(x($0) - p.x) < abs(x($1) - p.x) }), abs(x(hit) - p.x) <= 8 { onSelect?(hit) }
    }
}

/// Play button, position, seekbar with keyframe ticks, duration and the audio track toggles.
final class TransportViewController: ModelViewController {
    private var playButton = NSButton()
    private let positionLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private let slider = ScrubSlider()
    private let ticks = KeyTicksView()
    private let audioStack = NSStackView()
    private var builtAudio: [String] = []
    private var dragging = false

    override func loadView() {
        view = NSView()
        playButton = Kit.symbolButton("play.fill", tip: "Play / pause (space)", target: self, action: #selector(togglePlay))
        playButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        for l in [positionLabel, durationLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }

        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(scrubbed)
        slider.onBegin = { [weak self] in self?.dragging = true; self?.model.beginScrub() }
        slider.onEnd = { [weak self] in
            guard let self else { return }
            self.dragging = false
            self.model.endScrub(at: self.slider.doubleValue)
        }
        ticks.onSelect = { [weak self] in self?.model.select($0) }

        let seek = NSStackView(views: [slider, ticks])
        seek.orientation = .vertical
        seek.alignment = .width
        seek.spacing = 0
        seek.setHuggingPriority(.defaultLow, for: .horizontal)

        audioStack.orientation = .horizontal
        audioStack.spacing = 4

        let row = NSStackView(views: [playButton, positionLabel, seek, durationLabel, audioStack])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            row.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
    }

    override func refresh() {
        playButton.image = Kit.symbol(model.isPlaying ? "pause.fill" : "play.fill", "Play / pause")
        positionLabel.stringValue = Kit.time(model.position)
        durationLabel.stringValue = Kit.time(model.duration)
        slider.maxValue = max(model.duration, 0.1)
        if !dragging { slider.doubleValue = model.position }
        ticks.keys = model.keyframes
        ticks.selected = model.selectedKey
        ticks.duration = model.duration
        ticks.needsDisplay = true
        refreshAudio()
    }

    private func refreshAudio() {
        let ids = model.audioOptions.map { "\($0.id):\($0.label)" }
        if ids != builtAudio {
            builtAudio = ids
            audioStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if !model.audioOptions.isEmpty {
                audioStack.addArrangedSubview(NSImageView(image: Kit.symbol("speaker.wave.2", "Audio tracks")))
                for opt in model.audioOptions {
                    let b = Kit.button(opt.label, tip: "Include this audio track", target: self, action: #selector(audioToggled(_:)))
                    b.setButtonType(.pushOnPushOff)
                    b.tag = Int(opt.id)
                    audioStack.addArrangedSubview(b)
                }
            }
        }
        for case let b as NSButton in audioStack.arrangedSubviews {
            b.state = model.audioOptions.first { Int($0.id) == b.tag }?.enabled == true ? .on : .off
        }
    }

    @objc private func togglePlay() { model.togglePlay() }
    @objc private func scrubbed() { model.scrub(to: slider.doubleValue) }
    @objc private func audioToggled(_ sender: NSButton) { model.toggleAudio(CMPersistentTrackID(sender.tag)) }
}
