import AppKit

/// Right sidebar: export settings.
final class RightSidebarViewController: ModelViewController {
    private var presetPopup = NSPopUpButton()
    private let progressBar = NSProgressIndicator()

    override func loadView() {
        view = NSView()
        presetPopup = Kit.popup(Exporter.Preset.all.map(\.name), tip: "Resolution and format of the exported video",
                                target: self, action: #selector(presetChosen))
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        Kit.sidebarStack(in: view, [
            Kit.title("Export preset", tip: "Resolution and format used by the Export button in the toolbar."),
            presetPopup,
            progressBar,
        ])
    }

    override func refresh() {
        presetPopup.selectItem(at: Exporter.Preset.all.firstIndex(of: model.exportPreset) ?? 0)
        if let p = model.exportProgress {
            progressBar.doubleValue = p
            progressBar.toolTip = "Exporting… \(Int(p * 100))%"
        }
        progressBar.isHidden = model.exportProgress == nil
    }

    @objc private func presetChosen() {
        model.exportPreset = Exporter.Preset.all[presetPopup.indexOfSelectedItem]
    }
}
