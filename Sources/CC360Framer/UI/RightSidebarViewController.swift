import AVFoundation
import AppKit

/// Right sidebar: tabs for export, location card, keyframe inspector and audio tracks.
final class RightSidebarViewController: ModelViewController {
    private lazy var tabs: [(String, ModelViewController)] = [
        ("Export", ExportTabViewController(model: model)),
        ("Location", LocationTabViewController(model: model)),
        ("Inspector", InspectorTabViewController(model: model)),
        ("Audio", AudioTabViewController(model: model)),
    ]

    override func loadView() {
        for (_, vc) in tabs { addChild(vc) }
        view = Kit.TabContainer(tabs.map { (title: $0.0, page: $0.1.view) })
    }
}

/// Export format and size, and progress.
final class ExportTabViewController: ModelViewController {
    private let settingsView = ExportSettingsView()
    private let progressBar = NSProgressIndicator()
    private var frameCheck = NSButton()
    private var cutsCheck = NSButton()
    private var fovCheck = NSButton()
    private let fovSlider = NSSlider(value: 70, minValue: 20, maxValue: 140, target: nil, action: nil)
    private let fovValue = NSTextField(labelWithString: "70°")
    private var capPlacement = NSPopUpButton()
    private var capFont = NSPopUpButton()
    private var capSize = NSComboBox()
    private var capFill = NSColorWell()
    private var capStroke = NSColorWell()
    private let capStrokeWidth = NSSlider(value: 7, minValue: 0, maxValue: 20, target: nil, action: nil)
    private var capReset = NSButton()

    override func loadView() {
        view = NSView()
        frameCheck = NSButton(checkboxWithTitle: "Show export frame", target: self, action: #selector(frameToggled))
        frameCheck.toolTip = "Outline the exported area in the preview and dim the rest. Preview only, never exported. The vertical field of view is the same, so a different aspect ratio changes the horizontal extent."
        cutsCheck = NSButton(checkboxWithTitle: "Preview with cuts applied", target: self, action: #selector(cutsToggled))
        cutsCheck.toolTip = "Playback skips the cut regions (without the crossfade). The seekbar still shows the whole source video. Saved per video."
        settingsView.onChange = { [weak self] in self?.model.exportSettings = $0 }
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        fovCheck = NSButton(checkboxWithTitle: "Global FOV", target: self, action: #selector(fovChanged))
        fovCheck.toolTip = "Use one vertical field of view everywhere: it overrides the fov of all keyframes in the preview, the export and batch runs. While on, scroll and pinch zoom in the preview are disabled; use the slider."
        fovSlider.target = self; fovSlider.action = #selector(fovChanged)
        fovSlider.toolTip = "Vertical field of view in degrees, 20 to 140"
        fovValue.alignment = .right
        fovValue.setContentHuggingPriority(.required, for: .horizontal)
        let fovRow = NSStackView(views: [fovSlider, fovValue])
        fovRow.spacing = 6
        fovRow.identifier = Kit.fullWidthID
        settingsView.identifier = Kit.fullWidthID
        capPlacement = Kit.popup(OverlayPlacement.allCases.map(\.rawValue), tip: "Default placement of captions; a caption can override it in the Inspector tab",
                                 target: self, action: #selector(captionStyleChanged))
        capFont = Kit.fontPopup(tip: "Default caption font family", target: self, action: #selector(captionStyleChanged))
        capFont.insertItem(withTitle: CaptionStyle.systemFontName, at: 0)
        capSize = Kit.sizeCombo(presets: [3, 4, 5.5, 7, 9, 12, 15], tip: "Font size as a percentage of the frame's short side (2 to 15, pick a preset or type a number), so it looks the same at every export size",
                                target: self, action: #selector(captionStyleChanged))
        capFill = Kit.colorWell(.white, tip: "Default caption text colour", target: self, action: #selector(captionStyleChanged))
        capStroke = Kit.colorWell(.black, tip: "Default caption outline colour", target: self, action: #selector(captionStyleChanged))
        capStrokeWidth.target = self; capStrokeWidth.action = #selector(captionStyleChanged)
        capStrokeWidth.toolTip = "Outline width as a percentage of the font size (0 = none)"
        capReset = Kit.button("Reset captions look", tip: "Back to bottom centre, white text with a black outline", target: self, action: #selector(captionStyleReset))
        Kit.sidebarStack(in: view, [
            Kit.title("Export", tip: "Format and size used by the Export button in the toolbar. Saved per video and as the default for new videos."),
            settingsView,
            frameCheck,
            cutsCheck,
            fovCheck,
            fovRow,
            Kit.title("Captions", tip: "Default look of all captions (Captions timeline), in preview and export. Saved per video and as the default for other videos. Individual captions can override every setting in the Inspector tab."),
            capPlacement,
            Kit.labeledRow("Font", capFont),
            Kit.labeledRow("Size", capSize, tip: "Font size, % of the frame's short side"),
            Kit.labeledRow("Colour", capFill, tip: "Text colour"),
            Kit.labeledRow("Outline", capStroke, tip: "Outline colour"),
            Kit.labeledRow("Width", capStrokeWidth, tip: "Outline width, % of the font size"),
            capReset,
            progressBar,
        ], topAnchor: view.topAnchor)
    }

    override func refresh() {
        settingsView.settings = model.exportSettings
        frameCheck.state = model.showExportFrame ? .on : .off
        cutsCheck.state = model.previewWithCuts ? .on : .off
        fovCheck.state = model.globalFov.enabled ? .on : .off
        fovSlider.isEnabled = model.globalFov.enabled
        fovSlider.doubleValue = Double(model.globalFov.degrees)
        fovValue.stringValue = "\(Int(model.globalFov.degrees.rounded()))°"
        let cs = model.captionStyle
        capPlacement.selectItem(at: OverlayPlacement.allCases.firstIndex(of: cs.placement) ?? 0)
        capFont.selectItem(withTitle: cs.fontName ?? CaptionStyle.systemFontName)
        Kit.setSize(capSize, cs.size * 100)
        capStrokeWidth.doubleValue = cs.strokeWidth
        if capFill.color != cs.fill.nsColor { capFill.color = cs.fill.nsColor }
        if capStroke.color != cs.stroke.nsColor { capStroke.color = cs.stroke.nsColor }
        capReset.isEnabled = cs != CaptionStyle()
        if let p = model.exportProgress {
            progressBar.doubleValue = p
            progressBar.toolTip = "Exporting… \(Int(p * 100))%"
        }
        progressBar.isHidden = model.exportProgress == nil
    }

    @objc private func fovChanged() {
        var g = model.globalFov
        g.enabled = fovCheck.state == .on
        g.degrees = Float(fovSlider.doubleValue.rounded())
        model.globalFov = g
    }

    @objc private func captionStyleChanged(_ sender: Any?) {
        var s = model.captionStyle
        s.placement = OverlayPlacement.allCases[max(capPlacement.indexOfSelectedItem, 0)]
        s.fontName = capFont.indexOfSelectedItem == 0 ? nil : capFont.titleOfSelectedItem
        s.size = Kit.readSize(capSize, range: CaptionStyle.sizeRange.lowerBound * 100...CaptionStyle.sizeRange.upperBound * 100, step: 0.1, current: s.size * 100) / 100
        s.strokeWidth = capStrokeWidth.doubleValue.rounded()
        s.fill = CardColor(capFill.color)
        s.stroke = CardColor(capStroke.color)
        let name: String
        switch sender as AnyObject? {
        case let o where o === capPlacement: name = "Change Caption Placement"
        case let o where o === capFont: name = "Change Caption Font"
        case let o where o === capSize: name = "Change Caption Size"
        case let o where o === capFill: name = "Change Caption Colour"
        default: name = "Change Caption Outline"
        }
        model.setCaptionStyle(s, name: name)
    }

    @objc private func captionStyleReset() { model.setCaptionStyle(CaptionStyle(), name: "Reset Captions Look") }

    @objc private func cutsToggled() { model.previewWithCuts = cutsCheck.state == .on }

    @objc private func frameToggled() { model.showExportFrame = frameCheck.state == .on }
}

/// Audio tracks to include in playback and export.
final class AudioTabViewController: ModelViewController {
    private let stack = NSStackView()
    private let empty = NSTextField(wrappingLabelWithString: "No audio tracks.")
    private var built: [String] = []

    override func loadView() {
        view = NSView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        empty.textColor = .secondaryLabelColor
        Kit.sidebarStack(in: view, [Kit.title("Audio tracks", tip: "Tracks that are played and written to the export."), stack, empty],
                         topAnchor: view.topAnchor)
    }

    override func refresh() {
        let ids = model.audioOptions.map { "\($0.id):\($0.label)" }
        if ids != built {
            built = ids
            stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for opt in model.audioOptions {
                let b = NSButton(checkboxWithTitle: opt.label, target: self, action: #selector(toggled(_:)))
                b.tag = Int(opt.id)
                b.toolTip = "Include this audio track"
                stack.addArrangedSubview(b)
            }
        }
        for case let b as NSButton in stack.arrangedSubviews {
            b.state = model.audioOptions.first { Int($0.id) == b.tag }?.enabled == true ? .on : .off
        }
        empty.isHidden = !model.audioOptions.isEmpty
    }

    @objc private func toggled(_ sender: NSButton) { model.toggleAudio(CMPersistentTrackID(sender.tag)) }
}

/// Location card placement and look.
final class LocationTabViewController: ModelViewController {
    private var placementPopup = NSPopUpButton()
    private var fontPopup = NSPopUpButton()
    private var sizeCombo = NSComboBox()
    private var fillWell = NSColorWell()
    private var strokeWell = NSColorWell()
    private let strokeSlider = NSSlider(value: 0, minValue: 0, maxValue: 12, target: nil, action: nil)
    private var resetButton = NSButton()
    private var autoCheck = NSButton()
    private let autoNote = NSTextField(wrappingLabelWithString: "The automatic card is off while card keyframes exist. Add a keyframe at 0 s to show a card at the start.")
    private var showCheck = NSButton()
    private var fieldChecks: [(key: WritableKeyPath<LocationCardFields, Bool>, button: NSButton)] = []

    override func loadView() {
        view = NSView()
        showCheck = NSButton(checkboxWithTitle: "Show location card", target: self, action: #selector(showToggled))
        showCheck.toolTip = "Master switch: off hides the location card completely (automatic card and card keyframes, preview and export)."
        let defs: [(String, WritableKeyPath<LocationCardFields, Bool>, String)] = [
            ("Country", \.country, "Show the country"), ("City", \.city, "Show the city"),
            ("Street", \.street, "Show the street (above the city)"), ("House number", \.houseNumber, "Show the house number after the street (needs Street)"),
            ("Coordinates", \.coordinates, "Show latitude and longitude"), ("Elevation", \.elevation, "Show the elevation (when the GPS reports one)")]
        fieldChecks = defs.map { title, key, tip in
            let b = NSButton(checkboxWithTitle: title, target: self, action: #selector(fieldToggled))
            b.toolTip = tip + ". Applies to all location cards."
            return (key, b)
        }
        autoCheck = NSButton(checkboxWithTitle: "Automatic card at start", target: self, action: #selector(autoToggled))
        autoCheck.toolTip = "Show the card for the first 10 s of the video when no card keyframes exist. As soon as you add cards on the Location cards timeline only those are shown (add one at 0 s to keep a card at the start). A note below says when the automatic card is off for that reason."
        autoNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        autoNote.textColor = .secondaryLabelColor
        autoNote.identifier = Kit.fullWidthID
        autoNote.isHidden = true
        placementPopup = Kit.popup(OverlayPlacement.allCases.map(\.rawValue), tip: "Where the automatic card (first 10 s) is placed, and the placement of every card keyframe that does not override it (Inspector tab).",
                                   target: self, action: #selector(placementChosen))
        fontPopup = Kit.fontPopup(tip: "Font family of the card", target: self, action: #selector(styleChanged))
        fontPopup.insertItem(withTitle: "System", at: 0)
        sizeCombo = Kit.sizeCombo(presets: LocationCardStyle.sizePresets, tip: "Size of the first line in points at a 1080 px short side (scales with the frame); the other lines scale with it. Pick a preset or type a number, 8 to 400.",
                                  target: self, action: #selector(styleChanged))
        strokeSlider.target = self; strokeSlider.action = #selector(styleChanged)
        strokeSlider.toolTip = "Outline width in points (0 = none)"
        fillWell = Kit.colorWell(.white, tip: "Text colour", target: self, action: #selector(styleChanged))
        strokeWell = Kit.colorWell(.black, tip: "Outline colour", target: self, action: #selector(styleChanged))
        resetButton = Kit.button("Reset look", tip: "Back to the default font, size and colours", target: self, action: #selector(reset))
        Kit.sidebarStack(in: view, [
            Kit.title("Location card", tip: "Place-name card shown for 10 s, in preview and export: at the start of the video, or at the card keyframes of the Location cards timeline. The look below applies to all cards."),
            showCheck,
            autoCheck,
            autoNote,
            placementPopup,
        ] + fieldChecks.map(\.button) + [
            Kit.labeledRow("Font", fontPopup),
            Kit.labeledRow("Size", sizeCombo, tip: "Size of the first line in points (1080 px short side)"),
            Kit.labeledRow("Colour", fillWell, tip: "Text colour"),
            Kit.labeledRow("Outline", strokeWell, tip: "Outline colour"),
            Kit.labeledRow("Width", strokeSlider, tip: "Outline width in points"),
            resetButton,
        ], topAnchor: view.topAnchor)
    }

    override func refresh() {
        placementPopup.selectItem(at: OverlayPlacement.allCases.firstIndex(of: model.overlayPlacement) ?? 0)
        let s = model.cardStyle
        fontPopup.selectItem(withTitle: s.fontName ?? "System")
        Kit.setSize(sizeCombo, s.baseSize)
        strokeSlider.doubleValue = s.strokeWidth
        if fillWell.color != s.fill.nsColor { fillWell.color = s.fill.nsColor }
        if strokeWell.color != s.stroke.nsColor { strokeWell.color = s.stroke.nsColor }
        resetButton.isEnabled = s != LocationCardStyle()
        autoCheck.state = model.autoLocationCard ? .on : .off
        let o = model.cardOptions
        showCheck.state = o.show ? .on : .off
        for (key, b) in fieldChecks { b.state = o.fields[keyPath: key] ? .on : .off; b.isEnabled = o.show }
        autoCheck.isEnabled = o.show
        autoNote.isHidden = model.cardKeys.isEmpty   // status: the automatic card is ignored while card keyframes exist
    }

    @objc private func showToggled() {
        var o = model.cardOptions
        o.show = showCheck.state == .on
        model.setCardOptions(o, name: o.show ? "Show Location Card" : "Hide Location Card")
    }

    @objc private func fieldToggled() {
        var o = model.cardOptions
        for (key, b) in fieldChecks { o.fields[keyPath: key] = b.state == .on }
        model.setCardOptions(o)
    }

    @objc private func autoToggled() { model.setAutoLocationCard(autoCheck.state == .on) }

    @objc private func placementChosen() { model.overlayPlacement = OverlayPlacement.allCases[placementPopup.indexOfSelectedItem] }

    @objc private func styleChanged(_ sender: Any?) {
        var s = model.cardStyle
        s.fontName = fontPopup.indexOfSelectedItem == 0 ? nil : fontPopup.titleOfSelectedItem
        s.baseSize = Kit.readSize(sizeCombo, range: LocationCardStyle.sizeRange, current: s.baseSize)
        s.strokeWidth = (strokeSlider.doubleValue * 2).rounded() / 2
        s.fill = CardColor(fillWell.color)
        s.stroke = CardColor(strokeWell.color)
        let name: String
        switch sender as AnyObject? {
        case let o where o === fontPopup: name = "Change Card Font"
        case let o where o === sizeCombo: name = "Change Card Size"
        case let o where o === fillWell: name = "Change Card Colour"
        default: name = "Change Card Outline"
        }
        model.setCardStyle(s, name: name)
    }

    @objc private func reset() { model.setCardStyle(LocationCardStyle(), name: "Reset Card Look") }
}

/// Numeric editor for the selected timeline item: a keyframe, or the start and end of a cut.
final class InspectorTabViewController: ModelViewController, NSTextFieldDelegate, NSTextViewDelegate {
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let timeField = NSTextField(), yawField = NSTextField(), pitchField = NSTextField(), fovField = NSTextField()
    private let cutStartField = NSTextField(), cutEndField = NSTextField()
    private var fields: [NSTextField] { [timeField, yawField, pitchField, fovField, cutStartField, cutEndField, cardTimeField, capStartField, capEndField, ovSize, ovStrokeWidth] }
    private let cardTimeField = NSTextField()
    private var cardPlacementPopup = NSPopUpButton()
    private var cardOverrideCheck = NSButton()
    private let capStartField = NSTextField(), capEndField = NSTextField()
    private let capTextView = NSTextView()
    private var capScroll = NSScrollView()
    private var ovPlacement = NSPopUpButton(), ovFont = NSPopUpButton()
    private let ovSize = NSTextField(), ovStrokeWidth = NSTextField()
    private var ovFill = NSColorWell(), ovStroke = NSColorWell()
    private var ovReset = NSButton()
    private var keyForm: NSView!
    private var cutForm: NSView!
    private var cardForm: NSView!
    private var captionForm: NSView!
    private let heading = Kit.title("Keyframe", tip: "Edit the selected item; changes can be undone.")

    override func loadView() {
        view = NSView()
        empty.textColor = .secondaryLabelColor
        for f in fields {
            f.target = self
            f.action = #selector(commit)
            f.alignment = .right
            f.delegate = self
        }
        timeField.toolTip = "Seconds from the start"
        yawField.toolTip = "Degrees, -180 to 180 (0 = front)"
        pitchField.toolTip = "Degrees, -85 to 85"
        fovField.toolTip = "Vertical field of view in degrees, 20 to 140"
        cutStartField.toolTip = "Start of the cut in seconds of the source video"
        cutEndField.toolTip = "End of the cut in seconds of the source video"
        cardTimeField.toolTip = "Time in seconds of the source video at which the location card appears (it stays for 10 s)"
        cardPlacementPopup = Kit.popup(OverlayPlacement.allCases.map(\.rawValue), tip: "Where this location card is placed (the Location tab's placement while the override is off)", target: self, action: #selector(commit))
        cardOverrideCheck = NSButton(checkboxWithTitle: "Override placement", target: self, action: #selector(cardOverrideToggled))
        cardOverrideCheck.toolTip = "Off: this card uses the placement chosen in the Location tab. On: it has its own placement."
        func form(_ rows: [NSView]) -> NSStackView {
            let s = NSStackView(views: rows)
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 6
            for r in s.arrangedSubviews { r.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true }
            s.identifier = Kit.fullWidthID
            return s
        }
        keyForm = form([Kit.labeledRow("Time (s)", timeField), Kit.labeledRow("Yaw (°)", yawField),
                        Kit.labeledRow("Pitch (°)", pitchField), Kit.labeledRow("FOV (°)", fovField)])
        cutForm = form([Kit.labeledRow("Start (s)", cutStartField), Kit.labeledRow("End (s)", cutEndField)])
        capStartField.toolTip = "Start of the caption in seconds of the source video"
        capEndField.toolTip = "End of the caption in seconds of the source video"
        for f in [ovSize, ovStrokeWidth] { f.action = #selector(overrideFieldCommitted(_:)) }
        ovSize.placeholderString = "default"
        ovSize.toolTip = "Font size of this caption as a percentage of the frame's short side; empty = the default from the Export tab"
        ovStrokeWidth.placeholderString = "default"
        ovStrokeWidth.toolTip = "Outline width of this caption as a percentage of the font size; empty = the default from the Export tab"
        ovPlacement = Kit.popup(["Default"] + OverlayPlacement.allCases.map(\.rawValue), tip: "Placement of this caption; Default = the Export tab's",
                                target: self, action: #selector(overridesChanged))
        ovFont = Kit.fontPopup(tip: "Font family of this caption; Default = the Export tab's", target: self, action: #selector(overridesChanged))
        ovFont.insertItem(withTitle: CaptionStyle.systemFontName, at: 0)
        ovFont.insertItem(withTitle: "Default", at: 0)
        ovFill = Kit.colorWell(.white, tip: "Text colour of this caption (changing it overrides the default)", target: self, action: #selector(overridesChanged))
        ovStroke = Kit.colorWell(.black, tip: "Outline colour of this caption (changing it overrides the default)", target: self, action: #selector(overridesChanged))
        ovReset = Kit.button("Use defaults", tip: "Remove all overrides of this caption", target: self, action: #selector(overridesReset))
        capTextView.isRichText = false
        capTextView.allowsUndo = true
        capTextView.isAutomaticQuoteSubstitutionEnabled = false
        capTextView.isAutomaticDashSubstitutionEnabled = false
        capTextView.font = .systemFont(ofSize: NSFont.systemFontSize)
        capTextView.textContainerInset = NSSize(width: 2, height: 4)
        capTextView.isVerticallyResizable = true
        capTextView.autoresizingMask = [.width]
        capTextView.delegate = self
        capTextView.toolTip = "Caption text; Return starts a new line"
        capScroll.documentView = capTextView
        capScroll.hasVerticalScroller = true
        capScroll.borderType = .bezelBorder
        capScroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        captionForm = form([Kit.labeledRow("Start (s)", capStartField), Kit.labeledRow("End (s)", capEndField),
                            Kit.labeledRow("Text", capScroll, tip: "Caption text (several lines allowed)"),
                            Kit.title("Overrides", tip: "Settings of this caption that differ from the default look in the Export tab"),
                            Kit.labeledRow("Placement", ovPlacement), Kit.labeledRow("Font", ovFont),
                            Kit.labeledRow("Size (%)", ovSize), Kit.labeledRow("Colour", ovFill),
                            Kit.labeledRow("Outline", ovStroke), Kit.labeledRow("Width (%)", ovStrokeWidth), ovReset])
        cardForm = form([Kit.labeledRow("Time (s)", cardTimeField), cardOverrideCheck, Kit.labeledRow("Placement", cardPlacementPopup)])
        empty.identifier = Kit.fullWidthID
        Kit.sidebarStack(in: view, [heading, empty, keyForm, cutForm, cardForm, captionForm], topAnchor: view.topAnchor)
    }

    override func refresh() {
        let kind = model.activeTimeline
        let key = kind == .keyframes ? model.selectedKeyframe : nil
        let cut = kind == .cuts ? model.selectedCutRegion : nil
        let card = kind == .locationCards ? model.selectedCardKeyValue : nil
        let caption = kind == .captions ? model.selectedCaptionValue : nil
        heading.stringValue = kind == .cuts ? "Cut" : kind == .locationCards ? "Location card" : kind == .captions ? "Caption" : "Keyframe"
        switch kind {
        case .cuts: empty.stringValue = "Select a cut (click its bar under the seekbar) to edit it here."
        case .captions: empty.stringValue = "Select a caption (click its bar under the seekbar) to edit it here."
        case .locationCards: empty.stringValue = "Select a location card (click its diamond under the seekbar) to edit it here."
        default: empty.stringValue = "Select a keyframe (click a diamond under the seekbar) to edit it here."
        }
        empty.isHidden = key != nil || cut != nil || card != nil || caption != nil
        keyForm.isHidden = key == nil
        cutForm.isHidden = cut == nil
        cardForm.isHidden = card == nil
        captionForm.isHidden = caption == nil
        func show(_ f: NSTextField, _ x: Double, _ digits: Int) {
            if f.currentEditor() == nil { f.stringValue = String(format: "%.\(digits)f", x) }   // do not clobber typing
        }
        if let key {
            let v = KeyframeEdit.Values(key)
            show(timeField, v.time, 2); show(yawField, v.yaw, 1); show(pitchField, v.pitch, 1); show(fovField, v.fov, 1)
        }
        if let cut { show(cutStartField, cut.start, 2); show(cutEndField, cut.end, 2) }
        if let caption { showCaption(caption) }
        if let card {
            show(cardTimeField, card.time, 2)
            cardOverrideCheck.state = card.placement != nil ? .on : .off
            cardPlacementPopup.isEnabled = card.placement != nil
            cardPlacementPopup.selectItem(at: OverlayPlacement.allCases.firstIndex(of: card.effectivePlacement(global: model.overlayPlacement)) ?? 0)
        }
    }

    private func showCaption(_ c: Caption) {
        func show(_ f: NSTextField, _ x: Double, _ digits: Int) { if f.currentEditor() == nil { f.stringValue = String(format: "%.\(digits)f", x) } }
        show(capStartField, c.start, 2); show(capEndField, c.end, 2)
        if capTextView.string != c.text, capTextView.window?.firstResponder !== capTextView { capTextView.string = c.text }
        let o = c.overrides ?? CaptionOverrides()
        let r = c.style(over: model.captionStyle)
        ovPlacement.selectItem(at: o.placement.flatMap { OverlayPlacement.allCases.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        ovFont.selectItem(at: 0)
        if let f = o.fontName { ovFont.selectItem(withTitle: f) }
        if ovSize.currentEditor() == nil { ovSize.stringValue = o.size.map { String(format: "%.1f", $0 * 100) } ?? "" }
        if ovStrokeWidth.currentEditor() == nil { ovStrokeWidth.stringValue = o.strokeWidth.map { String(format: "%.0f", $0) } ?? "" }
        if ovFill.color != r.fill.nsColor { ovFill.color = r.fill.nsColor }
        if ovStroke.color != r.stroke.nsColor { ovStroke.color = r.stroke.nsColor }
        ovReset.isEnabled = !o.isEmpty
    }

    func textDidChange(_ notification: Notification) {
        let text = capTextView.string
        model.editSelectedCaption(name: "Edit Caption Text") { $0.text = text }
    }

    @objc private func overridesReset() { model.editSelectedCaption(name: "Reset Caption Overrides") { $0.overrides = nil } }

    @objc private func overridesChanged(_ sender: Any?) {
        guard let cap = model.selectedCaptionValue else { return }
        let before = cap.overrides ?? CaptionOverrides()
        let base = model.captionStyle
        var o = before
        let name: String
        switch sender as AnyObject? {
        case let v where v === ovPlacement:
            let i = ovPlacement.indexOfSelectedItem
            o.placement = i <= 0 ? nil : OverlayPlacement.allCases[i - 1]
            name = "Change Caption Placement"
        case let v where v === ovFont:
            o.fontName = ovFont.indexOfSelectedItem == 0 ? nil : ovFont.titleOfSelectedItem
            name = "Change Caption Font"
        case let v where v === ovFill:
            o.fill = CardColor(ovFill.color); name = "Change Caption Colour"
        case let v where v === ovStroke:
            o.stroke = CardColor(ovStroke.color); name = "Change Caption Outline"
        default: name = "Change Caption"
        }
        _ = base
        model.editSelectedCaption(name: name) { $0.overrides = o }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let f = obj.object as? NSTextField, f === ovSize || f === ovStrokeWidth { overrideFieldCommitted(f) }
    }

    @objc private func overrideFieldCommitted(_ f: NSTextField) {
        let v = Double(f.stringValue.replacingOccurrences(of: ",", with: "."))
        model.editSelectedCaption(name: f === ovSize ? "Change Caption Size" : "Change Caption Outline") {
            var o = $0.overrides ?? CaptionOverrides()
            if f === ovSize { o.size = v.map { $0 / 100 } } else { o.strokeWidth = v }
            $0.overrides = o
        }
    }

    private func parse(_ f: NSTextField, _ old: Double) -> Double { Double(f.stringValue.replacingOccurrences(of: ",", with: ".")) ?? old }

    @objc private func cardOverrideToggled() { model.setSelectedCardOverride(cardOverrideCheck.state == .on) }

    @objc private func commit() {
        if model.activeTimeline == .locationCards, let card = model.selectedCardKeyValue {
            let t = parse(cardTimeField, card.time)
            cardTimeField.abortEditing()
            let chosen = OverlayPlacement.allCases[max(cardPlacementPopup.indexOfSelectedItem, 0)]
            model.editSelectedCardKey(time: t, placement: card.placement == nil ? nil : chosen)
            refresh()
            return
        }
        if model.activeTimeline == .captions, let cap = model.selectedCaptionValue {
            let (s, e) = (parse(capStartField, cap.start), parse(capEndField, cap.end))
            for f in [capStartField, capEndField] { f.abortEditing() }
            model.editSelectedCaption(start: s, end: e)
            refresh()
            return
        }
        let cutFields = [cutStartField, cutEndField]
        if model.activeTimeline == .cuts, let cut = model.selectedCutRegion {
            let (s, e) = (parse(cutStartField, cut.start), parse(cutEndField, cut.end))
            for f in cutFields { f.abortEditing() }
            model.editSelectedCut(start: s, end: e)
            refresh()
            return
        }
        guard let key = model.selectedKeyframe else { return }
        var v = KeyframeEdit.Values(key)
        v.time = parse(timeField, v.time); v.yaw = parse(yawField, v.yaw)
        v.pitch = parse(pitchField, v.pitch); v.fov = parse(fovField, v.fov)
        for f in fields { f.abortEditing() }
        model.editSelectedKey(v)
        refresh()
    }
}
