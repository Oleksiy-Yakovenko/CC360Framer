import AppKit

/// Left sidebar: Auto, analysis, camera path style and stabilisation.
final class LeftSidebarViewController: ModelViewController {
    private let autoButton = NSButton()
    private let progress = NSProgressIndicator()
    private var cancelButton = NSButton()
    private var analyseButton = NSButton()
    private var buildButton = NSButton()
    private var reanalyseButton = NSButton()
    private var stylePopup = NSPopUpButton()
    private var stabilizePopup = NSPopUpButton()

    override func loadView() {
        view = NSView()

        autoButton.title = "Auto"
        autoButton.setButtonType(.pushOnPushOff)
        autoButton.bezelStyle = .rounded
        autoButton.target = self
        autoButton.action = #selector(autoToggled)
        autoButton.toolTip = "Follow the camera path. While on, the view tracks the keyframes at the playhead; dragging the view switches it off."

        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        cancelButton = Kit.button("Cancel", target: self, action: #selector(cancelJob))
        analyseButton = Kit.button("Analyse", tip: "Detect people and objects, then build a camera path", target: self, action: #selector(analyse))
        buildButton = Kit.button("Build path", tip: "Regenerate the path in this style (replaces keyframes)", target: self, action: #selector(buildPath))
        reanalyseButton = Kit.button("Re-analyse", tip: "Run the detection again", target: self, action: #selector(confirmReanalyse))

        stylePopup = Kit.popup(PathStyle.allCases.map(\.rawValue), tip: "How the camera path is generated", target: self, action: #selector(styleChosen))
        stabilizePopup = Kit.popup(StabilizeMode.allCases.map(\.rawValue), tip: "Horizon lock and shake removal from the camera's motion data", target: self, action: #selector(stabilizeChosen))

        let autoTitle = Kit.title("Auto", tip: "Follow the camera path: the view tracks the keyframes at the playhead.")
        let analysisTitle = Kit.title("Analysis", tip: "Detects people and objects; needed to build a camera path.")
        let pathTitle = Kit.title("Camera path", tip: "How the path is generated from the detections.")
        let stabTitle = Kit.title("Stabilise", tip: "Horizon lock and shake removal from the camera's motion data.")

        let stack = Kit.sidebarStack(in: view, [
            autoTitle, autoButton,
            analysisTitle, progress, cancelButton, analyseButton, buildButton, reanalyseButton,
            pathTitle, stylePopup,
            stabTitle, stabilizePopup,
        ])
        for v in [autoButton, reanalyseButton, stylePopup, stabilizePopup] { stack.setCustomSpacing(18, after: v) }
        stack.setCustomSpacing(18, after: analyseButton)
        stack.setCustomSpacing(18, after: buildButton)
        stack.setCustomSpacing(18, after: cancelButton)
    }

    override func refresh() {
        autoButton.state = model.autoFollow ? .on : .off
        autoButton.isEnabled = !model.keyframes.isEmpty

        let busy = model.analysisProgress
        let analysed = !model.observations.isEmpty
        progress.isHidden = busy == nil
        progress.doubleValue = busy ?? 0
        cancelButton.isHidden = busy == nil
        analyseButton.isHidden = busy != nil || analysed
        buildButton.isHidden = busy != nil || !analysed
        reanalyseButton.isHidden = busy != nil || !analysed

        stylePopup.selectItem(at: PathStyle.allCases.firstIndex(of: model.style) ?? 0)
        stabilizePopup.selectItem(at: StabilizeMode.allCases.firstIndex(of: model.stabilization) ?? 0)
    }

    @objc private func autoToggled() { model.autoFollow = autoButton.state == .on && !model.keyframes.isEmpty }
    @objc private func cancelJob() { model.cancelJob() }
    @objc private func analyse() { model.analyze() }
    @objc private func buildPath() { model.buildPath() }

    @objc private func confirmReanalyse() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Re-run the analysis?"
        alert.informativeText = "This takes several minutes and replaces the current detections and keyframes."
        alert.addButton(withTitle: "Re-analyse")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.analyze() }
        }
    }

    @objc private func styleChosen() {
        model.style = PathStyle.allCases[stylePopup.indexOfSelectedItem]
        model.styleChanged()
    }

    @objc private func stabilizeChosen() {
        model.stabilization = StabilizeMode.allCases[stabilizePopup.indexOfSelectedItem]
        model.stabilizationChanged()
    }
}
