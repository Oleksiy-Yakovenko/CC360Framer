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
/// A click selects (it does not move the playhead and shows the Inspector tab); dragging a region edge resizes it, the body moves it.
final class TimelineMarkersView: NSView {
    var adapter: TimelineAdapter?
    /// Called when a click selects an object (the window then shows its Inspector tab).
    var onUserSelect: (() -> Void)?
    var items: [TimelineItem] = []
    var selected: UUID?
    var duration: Double = 0 {
        didSet {
            if oldValue != duration { visibleDuration = TimelineWindow.initialVisible(duration: duration) }
        }
    }
    /// Current time, shown by the orange playhead at the horizontal centre (same value as the seekbar thumb); the window is centred on it.
    var playhead: Double = 0
    /// Seconds shown across the strip (wheel / pinch zoom; per session, not persisted).
    var visibleDuration: Double = TimelineWindow.defaultVisible
    /// Scrub hooks used while a drag autoscrolls (the controller forwards them to the model).
    var onScrubBegin: (() -> Void)?
    var onScrub: ((Double) -> Void)?
    var onScrubEnd: ((Double) -> Void)?
    private var dragging: (id: UUID, edge: RegionEdit.Edge)?
    /// Drag of a region body: the pointer's offset from the region start at mouseDown (seconds); `started` once the pointer moved a few px.
    private var bodyDrag: (id: UUID, offset: Double, downX: Double, started: Bool)?
    private static let bodyDragThreshold = 3.0
    private var dragX: Double = 0
    private var autoscrollTimer: Timer?
    private var autoscrollLast = CACurrentMediaTime()
    private var scrubStarted = false

    override var isFlipped: Bool { true }
    /// Height of the strip above the seekbar.
    static let height: CGFloat = 64
    /// Vertical band of the region bars (top and bottom margin), leaving room around them in the tall strip.
    private static let bandInset: CGFloat = 12
    private static let handleWidth: CGFloat = 4
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    private var layoutInfo: TimelineLayout {
        TimelineLayout(width: bounds.width, duration: duration, center: playhead, visible: TimelineWindow.clampVisible(visibleDuration, duration: duration))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        let l = layoutInfo
        // The video's own span is lighter than the empty area before 0 and after the end.
        let x0 = max(l.x(0), 0), x1 = min(l.x(duration), bounds.width)
        if x1 > x0 {
            NSColor(white: 0.13, alpha: 1).setFill()
            NSRect(x: x0, y: 0, width: x1 - x0, height: bounds.height).fill()
        }
        drawTicks(l)
        let overlapping = adapter?.kind == .audio   // clips may overlap: translucent bars with an outline, selected one on top
        for item in items.sorted(by: { ($0.id == selected ? 1 : 0) < ($1.id == selected ? 1 : 0) }) {
            let isSel = item.id == selected
            if let end = item.end, overlapping {
                let r = NSRect(x: l.x(item.start), y: Self.bandInset, width: max(l.x(end) - l.x(item.start), 2), height: bounds.height - Self.bandInset * 2)
                let base = isSel ? NSColor.controlAccentColor : NSColor.systemTeal
                base.withAlphaComponent(isSel ? 0.6 : 0.35).setFill()
                let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                path.fill()
                base.withAlphaComponent(0.95).setStroke()
                path.lineWidth = 1
                path.stroke()
                drawLabel(item.label, bar: r)
                if isSel {
                    NSColor.white.setFill()
                    for x in [r.minX, r.maxX - Self.handleWidth] { NSBezierPath(roundedRect: NSRect(x: x, y: r.minY, width: Self.handleWidth, height: r.height), xRadius: 1.5, yRadius: 1.5).fill() }
                }
            } else if let end = item.end {
                let r = NSRect(x: l.x(item.start), y: Self.bandInset, width: max(l.x(end) - l.x(item.start), 2), height: bounds.height - Self.bandInset * 2)
                (isSel ? NSColor.controlAccentColor : NSColor.systemRed).withAlphaComponent(isSel ? 0.9 : 0.7).setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
                if isSel {   // grab handles
                    NSColor.white.setFill()
                    for x in [r.minX, r.maxX - Self.handleWidth] { NSBezierPath(roundedRect: NSRect(x: x, y: r.minY, width: Self.handleWidth, height: r.height), xRadius: 1.5, yRadius: 1.5).fill() }
                }
            } else {
                let rad: CGFloat = isSel ? 8 : 6
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
        drawPlayhead(l)
    }

    private static let labelStyle: NSParagraphStyle = {
        let s = NSMutableParagraphStyle()
        s.lineBreakMode = .byTruncatingTail
        s.alignment = .center
        return s
    }()
    private static let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 1, alpha: 0.92), .paragraphStyle: labelStyle]

    /// Clip name centred on the visible part of the bar, cut with an ellipsis at the end when it does not fit.
    private func drawLabel(_ text: String, bar: NSRect) {
        guard !text.isEmpty, let span = TimelineLayout.visibleSpan(minX: bar.minX + 5, maxX: bar.maxX - 5, width: bounds.width) else { return }
        let h = ceil(NSFont.systemFont(ofSize: 11).boundingRectForFont.height)
        let rect = NSRect(x: span.lowerBound, y: bar.midY - h / 2, width: span.upperBound - span.lowerBound, height: h)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: Self.labelAttrs)
    }

    /// Dark grey ticks along the bottom, one per step (1 s, thinned when zoomed out), aligned to multiples of the step.
    private func drawTicks(_ l: TimelineLayout) {
        let step = TimelineWindow.tickStep(pixelsPerSecond: l.pixelsPerSecond)
        func draw(_ t: Double, _ h: CGFloat) { NSRect(x: l.x(t).rounded() - 0.5, y: bounds.height - h, width: 1, height: h).fill() }
        // The finer decade fades out as it gets too dense; its ticks that coincide with the step's are drawn by the step.
        let fine = TimelineWindow.fineTickAlpha(pixelsPerSecond: l.pixelsPerSecond, step: step)
        if fine > 0 {
            NSColor(white: 0.45, alpha: fine).setFill()
            for t in TimelineWindow.ticks(in: l.visibleRange, step: step / 10, duration: duration)
            where !TimelineWindow.isLargeTick(t, step: step / 10) { draw(t, 3) }
        }
        NSColor(white: 0.45, alpha: 1).setFill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                                                    .foregroundColor: NSColor(white: 0.6, alpha: 1)]
        for t in TimelineWindow.ticks(in: l.visibleRange, step: step, duration: duration) {
            let large = TimelineWindow.isLargeTick(t, step: step)
            draw(t, large ? 9 : 5)
            if large {   // the timestamp sits right of the large tick, in the band below the region bars
                NSAttributedString(string: TimelineWindow.largeTickText(t, step: step), attributes: attrs)
                    .draw(at: NSPoint(x: l.x(t).rounded() + 3, y: bounds.height - 12))
            }
        }
    }

    /// Orange line at the current time with a small time pill on top. Drawn only; `hitTest`/mouse handling ignore it.
    private func drawPlayhead(_ l: TimelineLayout) {
        let x = l.playheadX.rounded() + 0.5
        NSColor.systemOrange.setFill()
        NSRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(white: 0.1, alpha: 1)]
        let text = NSAttributedString(string: TimelineLayout.timeText(playhead), attributes: attrs)
        let ts = text.size()
        let w = ceil(ts.width) + 10, h = ceil(ts.height) + 2
        let pill = NSRect(x: l.labelOriginX(centerX: x, labelWidth: w), y: 2, width: w, height: h)
        NSColor(white: 0.95, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
        text.draw(at: NSPoint(x: pill.minX + 5, y: pill.minY + 1))
    }

    override func mouseDown(with event: NSEvent) {
        guard let adapter else { return }
        let p = convert(event.locationInWindow, from: nil)
        let hit = layoutInfo.hit(items, selected: selected, at: p.x)
        switch hit {
        case .point(let id): adapter.selectQuietly(id)   // a click selects; it never moves the playhead or the window
        case .region(let id):
            // A click only selects (no seek: the window stays where it is); dragging the body moves the region.
            adapter.selectQuietly(id)
            if let item = items.first(where: { $0.id == id }) {
                bodyDrag = (id, layoutInfo.time(p.x) - item.start, Double(p.x), false)
            }
        case .regionStart(let id): startDrag(adapter, id, .start)
        case .regionEnd(let id): startDrag(adapter, id, .end)
        case nil: break
        }
        if case .some = hit { onUserSelect?() }
    }

    private func startDrag(_ adapter: TimelineAdapter, _ id: UUID, _ edge: RegionEdit.Edge) {
        adapter.selectQuietly(id)
        adapter.beginDrag()
        dragging = (id, edge)
    }

    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        if var b = bodyDrag, !b.started {
            guard abs(x - b.downX) > Self.bodyDragThreshold else { return }
            b.started = true
            bodyDrag = b
            adapter?.beginDrag()
        }
        guard dragging != nil || bodyDrag != nil else { return }
        dragX = x
        applyDrag()
        updateAutoscrollTimer()
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        if let b = bodyDrag {
            bodyDrag = nil
            if b.started { adapter?.endMove() }
        } else if dragging != nil {
            dragging = nil
            adapter?.endDrag()
        } else {
            return
        }
        if scrubStarted {
            scrubStarted = false
            onScrubEnd?(playhead)
        }
    }

    /// Moves the dragged edge to the time under the pointer in the current window.
    private func applyDrag() {
        guard let adapter else { return }
        if let b = bodyDrag {
            if b.started { adapter.dragRegion(b.id, to: layoutInfo.time(dragX) - b.offset) }
        } else if let d = dragging {
            adapter.drag(d.id, edge: d.edge, to: layoutInfo.time(dragX))
        }
    }

    private func updateAutoscrollTimer() {
        let speed = TimelineWindow.autoscrollSpeed(pointerX: dragX, width: bounds.width, visible: layoutInfo.visible)
        if speed == 0 { stopAutoscroll(); return }
        guard autoscrollTimer == nil else { return }
        autoscrollLast = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            MainActor.assumeIsolated { self.autoscrollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoscrollTimer = timer
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    /// While the pointer is held near an edge the playhead (and so the window) moves; the edge follows the pointer's time.
    private func autoscrollTick() {
        let now = CACurrentMediaTime()
        let dt = min(now - autoscrollLast, 0.1)
        autoscrollLast = now
        guard dragging != nil || bodyDrag?.started == true else { stopAutoscroll(); return }
        let speed = TimelineWindow.autoscrollSpeed(pointerX: dragX, width: bounds.width, visible: layoutInfo.visible)
        if speed == 0 { stopAutoscroll(); return }
        let t = max(0, min(duration, playhead + speed * dt))
        guard t != playhead else { return }
        if !scrubStarted { scrubStarted = true; onScrubBegin?() }
        playhead = t
        onScrub?(t)
        applyDrag()
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = Double(event.scrollingDeltaY)
        guard duration > 0, dy != 0 else { return }   // handled either way: never scroll the surrounding UI
        zoom(by: TimelineWindow.wheelFactor(deltaY: dy, precise: event.hasPreciseScrollingDeltas))
    }

    override func magnify(with event: NSEvent) {
        guard duration > 0 else { return }
        zoom(by: TimelineWindow.magnifyFactor(Double(event.magnification)))
    }

    private func zoom(by factor: Double) {
        let v = TimelineWindow.clampVisible(visibleDuration * factor, duration: duration)
        guard v != visibleDuration else { return }
        visibleDuration = v
        needsDisplay = true
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
    /// Called when a click on the timeline strip selects an object.
    var onSelectItem: (() -> Void)? {
        get { ticks.onUserSelect }
        set { ticks.onUserSelect = newValue }
    }

    override func loadView() {
        view = NSView()
        playButton = Kit.symbolButton("play.fill", tip: "Play / pause (space)", target: self, action: #selector(togglePlay))
        playButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        recordButton = Kit.symbolButton("record.circle.fill", tip: "Record camera moves: while on, dragging and zooming the preview adds keyframes",
                                        target: self, action: #selector(toggleRecord))
        recordButton.setButtonType(.pushOnPushOff)
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
        ticks.onScrubBegin = { [weak self] in self?.model.beginScrub() }
        ticks.onScrub = { [weak self] t in self?.model.scrub(to: t) }
        ticks.onScrubEnd = { [weak self] t in self?.model.endScrub(at: t) }

        // The strip is not part of the row (the play button and labels stay centred on the slider) and spans the whole width
        // of the container: it shows a zoomable window centred on the playhead, so it need not line up with the slider.
        let row = NSStackView(views: [playButton, recordButton, positionLabel, slider, durationLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        ticks.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ticks)
        NSLayoutConstraint.activate([
            ticks.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ticks.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        recordButton.image = Self.recordImage()
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
        ticks.playhead = dragging ? slider.doubleValue : model.position
        ticks.needsDisplay = true
    }

    /// `record.circle.fill` in both states (the pushed-in bezel shows that recording is on), drawn in red by the symbol itself:
    /// a palette configuration is not overridden by the button's tinting (`contentTintColor` is ignored for a pushed-in rounded button).
    private static func recordImage() -> NSImage {
        let base = Kit.symbol("record.circle.fill", "Record camera moves")
        return base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) ?? base
    }

    @objc private func togglePlay() { model.togglePlay() }
    @objc private func toggleRecord() { model.toggleRecording() }
    @objc private func scrubbed() {
        ticks.playhead = slider.doubleValue
        ticks.needsDisplay = true
        model.scrub(to: slider.doubleValue)
    }
}
