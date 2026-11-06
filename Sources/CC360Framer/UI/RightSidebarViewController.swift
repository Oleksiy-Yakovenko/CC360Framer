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
    private var fovCheck = NSButton()
    private let fovSlider = NSSlider(value: 70, minValue: 20, maxValue: 140, target: nil, action: nil)
    private let fovValue = NSTextField(labelWithString: "70°")

    override func loadView() {
        view = NSView()
        frameCheck = NSButton(checkboxWithTitle: "Show export frame", target: self, action: #selector(frameToggled))
        frameCheck.toolTip = "Outline the exported area in the preview and dim the rest. Preview only, never exported. The vertical field of view is the same, so a different aspect ratio changes the horizontal extent."
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
        Kit.sidebarStack(in: view, [
            Kit.title("Export", tip: "Format and size used by the Export button in the toolbar. Saved per video and as the default for new videos."),
            settingsView,
            frameCheck,
            fovCheck,
            fovRow,
            progressBar,
        ], topAnchor: view.topAnchor)
    }

    override func refresh() {
        settingsView.settings = model.exportSettings
        frameCheck.state = model.showExportFrame ? .on : .off
        fovCheck.state = model.globalFov.enabled ? .on : .off
        fovSlider.isEnabled = model.globalFov.enabled
        fovSlider.doubleValue = Double(model.globalFov.degrees)
        fovValue.stringValue = "\(Int(model.globalFov.degrees.rounded()))°"
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
    private let sizeSlider = NSSlider(value: 64, minValue: 24, maxValue: 120, target: nil, action: nil)
    private var fillWell = NSColorWell()
    private var strokeWell = NSColorWell()
    private let strokeSlider = NSSlider(value: 0, minValue: 0, maxValue: 12, target: nil, action: nil)
    private var resetButton = NSButton()

    override func loadView() {
        view = NSView()
        placementPopup = Kit.popup(OverlayPlacement.allCases.map(\.rawValue), tip: "Where the location card (first 10 s) is placed, in preview and export",
                                   target: self, action: #selector(placementChosen))
        fontPopup = Kit.fontPopup(tip: "Font family of the card", target: self, action: #selector(styleChanged))
        fontPopup.insertItem(withTitle: "System", at: 0)
        sizeSlider.target = self; sizeSlider.action = #selector(styleChanged)
        sizeSlider.toolTip = "Size of the first line in points; the other lines scale with it"
        strokeSlider.target = self; strokeSlider.action = #selector(styleChanged)
        strokeSlider.toolTip = "Outline width in points (0 = none)"
        fillWell = Kit.colorWell(.white, tip: "Text colour", target: self, action: #selector(styleChanged))
        strokeWell = Kit.colorWell(.black, tip: "Outline colour", target: self, action: #selector(styleChanged))
        resetButton = Kit.button("Reset look", tip: "Back to the default font, size and colours", target: self, action: #selector(reset))
        Kit.sidebarStack(in: view, [
            Kit.title("Location card", tip: "Place-name card shown during the first 10 s, in preview and export."),
            placementPopup,
            Kit.labeledRow("Font", fontPopup),
            Kit.labeledRow("Size", sizeSlider, tip: "Size of the first line in points"),
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
        sizeSlider.doubleValue = s.baseSize
        strokeSlider.doubleValue = s.strokeWidth
        if fillWell.color != s.fill.nsColor { fillWell.color = s.fill.nsColor }
        if strokeWell.color != s.stroke.nsColor { strokeWell.color = s.stroke.nsColor }
        resetButton.isEnabled = s != LocationCardStyle()
    }

    @objc private func placementChosen() { model.overlayPlacement = OverlayPlacement.allCases[placementPopup.indexOfSelectedItem] }

    @objc private func styleChanged(_ sender: Any?) {
        var s = model.cardStyle
        s.fontName = fontPopup.indexOfSelectedItem == 0 ? nil : fontPopup.titleOfSelectedItem
        s.baseSize = sizeSlider.doubleValue.rounded()
        s.strokeWidth = (strokeSlider.doubleValue * 2).rounded() / 2
        s.fill = CardColor(fillWell.color)
        s.stroke = CardColor(strokeWell.color)
        let name: String
        switch sender as AnyObject? {
        case let o where o === fontPopup: name = "Change Card Font"
        case let o where o === sizeSlider: name = "Change Card Size"
        case let o where o === fillWell: name = "Change Card Colour"
        default: name = "Change Card Outline"
        }
        model.setCardStyle(s, name: name)
    }

    @objc private func reset() { model.setCardStyle(LocationCardStyle(), name: "Reset Card Look") }
}

/// Numeric editor for the selected keyframe.
final class InspectorTabViewController: ModelViewController, NSTextFieldDelegate {
    private let empty = NSTextField(wrappingLabelWithString: "Select a keyframe (click a diamond under the seekbar) to edit it here.")
    private let timeField = NSTextField(), yawField = NSTextField(), pitchField = NSTextField(), fovField = NSTextField()
    private var fields: [NSTextField] { [timeField, yawField, pitchField, fovField] }
    private var form: NSView!

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
        let rows = NSStackView(views: [
            Kit.labeledRow("Time (s)", timeField), Kit.labeledRow("Yaw (°)", yawField),
            Kit.labeledRow("Pitch (°)", pitchField), Kit.labeledRow("FOV (°)", fovField),
        ])
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        for r in rows.arrangedSubviews { r.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true }
        form = rows
        empty.identifier = Kit.fullWidthID
        rows.identifier = Kit.fullWidthID
        Kit.sidebarStack(in: view, [Kit.title("Keyframe", tip: "Edit the selected keyframe; changes can be undone."), empty, rows], topAnchor: view.topAnchor)
    }

    override func refresh() {
        let key = model.selectedKeyframe
        empty.isHidden = key != nil
        form.isHidden = key == nil
        guard let key else { return }
        let v = KeyframeEdit.Values(key)
        func show(_ f: NSTextField, _ x: Double, _ digits: Int) {
            if f.currentEditor() == nil { f.stringValue = String(format: "%.\(digits)f", x) }   // do not clobber typing
        }
        show(timeField, v.time, 2); show(yawField, v.yaw, 1); show(pitchField, v.pitch, 1); show(fovField, v.fov, 1)
    }

    @objc private func commit() {
        guard let key = model.selectedKeyframe else { return }
        var v = KeyframeEdit.Values(key)
        func parse(_ f: NSTextField, _ old: Double) -> Double { Double(f.stringValue.replacingOccurrences(of: ",", with: ".")) ?? old }
        v.time = parse(timeField, v.time); v.yaw = parse(yawField, v.yaw)
        v.pitch = parse(pitchField, v.pitch); v.fov = parse(fovField, v.fov)
        for f in fields { f.abortEditing() }
        model.editSelectedKey(v)
        refresh()
    }
}
