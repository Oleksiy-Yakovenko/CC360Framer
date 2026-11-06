import AppKit

/// Editor for an `ExportSettings` value. Shared by the right sidebar's Export tab and the batch window: set `settings`
/// to show a value, `onChange` fires with the edited value when the user changes a control.
final class ExportSettingsView: NSView, NSTextFieldDelegate {
    var onChange: ((ExportSettings) -> Void)?
    var settings = ExportSettings() { didSet { if settings != oldValue { syncControls() } } }

    private var containerPopup = NSPopUpButton(), codecPopup = NSPopUpButton(), ratePopup = NSPopUpButton()
    private var resolutionPopup = NSPopUpButton(), aspectPopup = NSPopUpButton()
    private let bitrateField = NSTextField(), qualitySlider = NSSlider(value: 0.7, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let widthField = NSTextField(), aspectW = NSTextField(), aspectH = NSTextField()
    private let crossfadeField = NSTextField()
    private let sizeLabel = NSTextField(labelWithString: "")
    private var bitrateRow: NSView!, qualityRow: NSView!, widthRow: NSView!, aspectRow: NSView!

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        containerPopup = Kit.popup(ExportSettings.Container.allCases.map(\.label), tip: "File format; the extension follows it", target: self, action: #selector(changed))
        codecPopup = Kit.popup(ExportSettings.Codec.allCases.map(\.label), tip: "Video codec. HEVC is smaller, H.264 plays everywhere", target: self, action: #selector(changed))
        ratePopup = Kit.popup(ExportSettings.RateControl.allCases.map(\.label), tip: "Fixed average bitrate, or a quality level that lets the size vary", target: self, action: #selector(changed))
        resolutionPopup = Kit.popup(ExportSettings.Resolution.allCases.map(\.label), tip: "Short side of the output (1080p = 1080 px), or a custom width", target: self, action: #selector(changed))
        aspectPopup = Kit.popup(ExportSettings.Aspect.allCases.map(\.label), tip: "Aspect ratio of the exported video. The vertical field of view stays the same, so a different ratio changes the horizontal extent", target: self, action: #selector(changed))
        qualitySlider.target = self; qualitySlider.action = #selector(changed)
        qualitySlider.toolTip = "Encoder quality, 0.1 (small) to 1 (best)"
        bitrateField.placeholderString = "auto"
        bitrateField.toolTip = "Average video bitrate in Mbps; empty = automatic (20 Mbps, 50 Mbps above 3 MP)"
        widthField.toolTip = "Output width in pixels (16 to 8192)"
        aspectW.toolTip = "Aspect width"; aspectH.toolTip = "Aspect height"
        crossfadeField.toolTip = "Length of the dissolve at cuts in seconds (0 = hard cut)"
        for f in [bitrateField, widthField, aspectW, aspectH, crossfadeField] {
            f.alignment = .right; f.delegate = self; f.target = self; f.action = #selector(changed)
        }
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.toolTip = "Resulting output size in pixels"
        let mbps = NSStackView(views: [bitrateField, NSTextField(labelWithString: "Mbps")])
        mbps.spacing = 4
        let aspectBox = NSStackView(views: [aspectW, NSTextField(labelWithString: ":"), aspectH])
        aspectBox.spacing = 4
        bitrateRow = Kit.labeledRow("Bitrate", mbps, tip: "Average video bitrate")
        qualityRow = Kit.labeledRow("Level", qualitySlider, tip: "Encoder quality")
        widthRow = Kit.labeledRow("Width", widthField, tip: "Output width in pixels")
        aspectRow = Kit.labeledRow("Ratio", aspectBox, tip: "Custom aspect ratio width : height")
        let rows: [NSView] = [
            Kit.labeledRow("Format", containerPopup, tip: "File format"),
            Kit.labeledRow("Codec", codecPopup, tip: "Video codec"),
            Kit.labeledRow("Rate", ratePopup, tip: "Rate control"),
            bitrateRow, qualityRow,
            Kit.labeledRow("Resolution", resolutionPopup, tip: "Short side of the output"), widthRow,
            Kit.labeledRow("Aspect", aspectPopup, tip: "Aspect ratio of the output"), aspectRow,
            Kit.labeledRow("Size", sizeLabel, tip: "Resulting output size in pixels"),
            Kit.labeledRow("Crossfade (s)", crossfadeField, tip: "Length of the dissolve at cuts in seconds"),
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for r in rows { r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        syncControls()
    }

    private func syncControls() {
        let s = settings
        containerPopup.selectItem(at: ExportSettings.Container.allCases.firstIndex(of: s.container) ?? 0)
        codecPopup.selectItem(at: ExportSettings.Codec.allCases.firstIndex(of: s.codec) ?? 0)
        ratePopup.selectItem(at: ExportSettings.RateControl.allCases.firstIndex(of: s.rateControl) ?? 0)
        resolutionPopup.selectItem(at: ExportSettings.Resolution.allCases.firstIndex(of: s.resolution) ?? 0)
        aspectPopup.selectItem(at: ExportSettings.Aspect.allCases.firstIndex(of: s.aspect) ?? 0)
        func show(_ f: NSTextField, _ text: String) { if f.currentEditor() == nil { f.stringValue = text } }   // do not clobber typing
        show(bitrateField, s.bitrateMbps.map { String(format: "%g", $0) } ?? "")
        show(widthField, "\(s.customWidth)")
        show(aspectW, "\(s.customAspectW)"); show(aspectH, "\(s.customAspectH)")
        show(crossfadeField, String(format: "%g", s.crossfade))
        qualitySlider.doubleValue = s.quality
        bitrateRow.isHidden = s.rateControl != .bitrate
        qualityRow.isHidden = s.rateControl != .quality
        widthRow.isHidden = s.resolution != .custom
        aspectRow.isHidden = s.aspect != .custom
        let o = s.outputSize
        sizeLabel.stringValue = "\(o.width) × \(o.height)"
    }

    @objc private func changed() {
        var s = settings
        func pick<T: CaseIterable>(_ p: NSPopUpButton, _ cur: T) -> T where T.AllCases: RandomAccessCollection, T.AllCases.Index == Int {
            let i = p.indexOfSelectedItem
            return i >= 0 && i < T.allCases.count ? T.allCases[i] : cur
        }
        func num(_ f: NSTextField) -> Double? { Double(f.stringValue.replacingOccurrences(of: ",", with: ".")) }
        s.container = pick(containerPopup, s.container)
        s.codec = pick(codecPopup, s.codec)
        s.rateControl = pick(ratePopup, s.rateControl)
        s.resolution = pick(resolutionPopup, s.resolution)
        s.aspect = pick(aspectPopup, s.aspect)
        s.bitrateMbps = num(bitrateField).flatMap { $0 > 0 ? $0 : nil }
        s.quality = qualitySlider.doubleValue
        if let w = num(widthField) { s.customWidth = min(max(Int(w), 16), 8192) }
        if let w = num(aspectW), w >= 1 { s.customAspectW = min(Int(w), 100) }
        if let h = num(aspectH), h >= 1 { s.customAspectH = min(Int(h), 100) }
        if let c = num(crossfadeField) { s.crossfade = min(max(c, 0), 5) }
        guard s != settings else { return }
        settings = s
        onChange?(s)
    }

    func controlTextDidEndEditing(_ obj: Notification) { changed() }
}
