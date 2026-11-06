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

/// Markers of the active timeline on a black strip above the seekbar: diamonds for points, bars with draggable edges for regions.
/// Click selects (and seeks); dragging a region edge resizes it.
final class TimelineMarkersView: NSView {
    var adapter: TimelineAdapter?
    var items: [TimelineItem] = []
    var selected: UUID?
    var duration: Double = 0
    private var dragging: (id: UUID, edge: RegionEdit.Edge)?

    override var isFlipped: Bool { true }
    /// Height of the strip above the seekbar.
    static let height: CGFloat = 32
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    private var layoutInfo: TimelineLayout { TimelineLayout(width: bounds.width, duration: duration) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let l = layoutInfo
        for item in items {
            let isSel = item.id == selected
            if let end = item.end {
                let r = NSRect(x: l.x(item.start), y: 4, width: max(l.x(end) - l.x(item.start), 2), height: bounds.height - 8)
                (isSel ? NSColor.controlAccentColor : NSColor.systemRed).withAlphaComponent(isSel ? 0.9 : 0.7).setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                if isSel {   // grab handles
                    NSColor.white.setFill()
                    for x in [r.minX, r.maxX - 3] { NSBezierPath(roundedRect: NSRect(x: x, y: r.minY + 2, width: 3, height: r.height - 4), xRadius: 1, yRadius: 1).fill() }
                }
            } else {
                let rad: CGFloat = isSel ? 5 : 3.5
                let c = CGPoint(x: l.x(item.start), y: bounds.midY)
                let path = NSBezierPath()
                path.move(to: CGPoint(x: c.x, y: c.y - rad))
                path.line(to: CGPoint(x: c.x + rad, y: c.y))
                path.line(to: CGPoint(x: c.x, y: c.y + rad))
                path.line(to: CGPoint(x: c.x - rad, y: c.y))
                path.close()
                (isSel ? NSColor.controlAccentColor : NSColor.systemOrange).setFill()
                path.fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let adapter else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch layoutInfo.hit(items, selected: selected, at: p.x) {
        case .point(let id), .region(let id): adapter.select(id)
        case .regionStart(let id): startDrag(adapter, id, .start)
        case .regionEnd(let id): startDrag(adapter, id, .end)
        case nil: break
        }
    }

    private func startDrag(_ adapter: TimelineAdapter, _ id: UUID, _ edge: RegionEdit.Edge) {
        adapter.selectQuietly(id)
        adapter.beginDrag()
        dragging = (id, edge)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let adapter, let d = dragging else { return }
        adapter.drag(d.id, edge: d.edge, to: layoutInfo.time(convert(event.locationInWindow, from: nil).x))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging != nil else { return }
        dragging = nil
        adapter?.endDrag()
    }
}

/// Play button, position, seekbar with the active timeline's markers, duration.
final class TransportViewController: ModelViewController {
    private var playButton = NSButton()
    private var recordButton = NSButton()
    private let positionLabel = NSTextField(labelWithString: "0:00")
    private let durationLabel = NSTextField(labelWithString: "0:00")
    private let slider = ScrubSlider()
    private let ticks = TimelineMarkersView()
    private var dragging = false

    override func loadView() {
        view = NSView()
        playButton = Kit.symbolButton("play.fill", tip: "Play / pause (space)", target: self, action: #selector(togglePlay))
        playButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        recordButton = Kit.symbolButton("record.circle", tip: "Record camera moves: while on, dragging and zooming the preview adds keyframes",
                                        target: self, action: #selector(toggleRecord))
        recordButton.setButtonType(.pushOnPushOff)
        recordButton.contentTintColor = .systemRed
        recordButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
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

        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // The strip is not part of the row, so the play button and labels stay centred on the slider; its edges are
        // pinned to the slider's, so times map to the same x as the thumb.
        let row = NSStackView(views: [playButton, recordButton, positionLabel, slider, durationLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        ticks.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ticks)
        NSLayoutConstraint.activate([
            ticks.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            ticks.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            ticks.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            ticks.heightAnchor.constraint(equalToConstant: TimelineMarkersView.height),
            row.topAnchor.constraint(equalTo: ticks.bottomAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -4),
        ])
    }

    override func refresh() {
        playButton.image = Kit.symbol(model.isPlaying ? "pause.fill" : "play.fill", "Play / pause")
        recordButton.image = Kit.symbol(model.isRecording ? "record.circle.fill" : "record.circle", "Record camera moves")
        recordButton.state = model.isRecording ? .on : .off
        recordButton.isEnabled = model.duration > 0
        positionLabel.stringValue = Kit.time(model.position)
        durationLabel.stringValue = Kit.time(model.duration)
        slider.maxValue = max(model.duration, 0.1)
        if !dragging { slider.doubleValue = model.position }
        let timeline = model.timeline
        ticks.adapter = timeline
        ticks.items = timeline.items
        ticks.selected = timeline.selected
        ticks.duration = model.duration
        ticks.needsDisplay = true
    }

    @objc private func togglePlay() { model.togglePlay() }
    @objc private func toggleRecord() { model.toggleRecording() }
    @objc private func scrubbed() { model.scrub(to: slider.doubleValue) }
}
