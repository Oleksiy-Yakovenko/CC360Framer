import AppKit

/// Right sidebar: export settings.
final class RightSidebarViewController: ModelViewController {
    private var presetPopup = NSPopUpButton()

    override func loadView() {
        view = NSView()
        presetPopup = Kit.popup(Exporter.Preset.all.map(\.name), tip: "Resolution and format of the exported video",
                                target: self, action: #selector(presetChosen))
        Kit.sidebarStack(in: view, [
            Kit.title("Export preset"),
            Kit.caption("Resolution and format used by the Export button in the toolbar."),
            presetPopup,
        ])
    }

    override func refresh() {
        presetPopup.selectItem(at: Exporter.Preset.all.firstIndex(of: model.exportPreset) ?? 0)
    }

    @objc private func presetChosen() {
        model.exportPreset = Exporter.Preset.all[presetPopup.indexOfSelectedItem]
    }
}
