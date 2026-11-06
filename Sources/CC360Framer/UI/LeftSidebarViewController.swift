import AppKit

/// Left sidebar: Auto, analysis, camera path style and stabilisation.
final class LeftSidebarViewController: ModelViewController {
    private let autoButton = NSButton()
    private let progress = NSProgressIndicator()
    private var cancelButton = NSButton()
    private var analyseButton = NSButton()
    private var buildButton = NSButton()
    private var reanalyseButton = NSButton()
    private let detectionsCheck = NSButton(checkboxWithTitle: "Display detected subjects", target: nil, action: nil)
    private var qualityPopup = NSPopUpButton()
    private var stylePopup = NSPopUpButton()
    private var forwardPopup = NSPopUpButton()
    private let lockCheck = NSButton(checkboxWithTitle: "Direction lock", target: nil, action: nil)
    private let lockNote = NSTextField(wrappingLabelWithString: "")
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

        qualityPopup = Kit.popup(AnalysisQuality.allCases.map(\.rawValue), tip: AnalysisQuality.popupTip, target: self, action: #selector(qualityChosen))
        stylePopup = Kit.popup(PathStyle.allCases.map(\.rawValue), tip: "How the camera path is generated", target: self, action: #selector(styleChosen))
        forwardPopup = Kit.popup(TravelDirection.ForwardMode.allCases.map(\.title), tip: "Where the Scenery shots that look straight ahead are aimed: along the direction of travel (found from the accelerometer and GPS; needs movement and GPS) or straight ahead of the camera.", target: self, action: #selector(forwardChosen))
        stabilizePopup = Kit.popup(StabilizeMode.allCases.map(\.rawValue), tip: "Horizon lock and shake removal from the camera's motion data", target: self, action: #selector(stabilizeChosen))

        detectionsCheck.target = self
        detectionsCheck.action = #selector(detectionsToggled)
        detectionsCheck.toolTip = "Preview only: outline the people (green) and objects (yellow) found by the analysis at the nearest analysed frame (about 5 per second). Duplicates seen in two overlapping analysis views are merged, and groups of 3 or more people get one extra cyan dashed box. Analyses made by older versions have no boxes: re-analyse to get them."

        lockCheck.target = self
        lockCheck.action = #selector(lockToggled)
        lockCheck.toolTip = "Rotate the preview to the direction you consider forward; the last direction you set is kept (with the file). While ticked it is used for the Scenery forward shots, the double-click reset and the initial view, and it overrides the Forward setting."

        lockNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        lockNote.textColor = .secondaryLabelColor
        lockNote.identifier = Kit.fullWidthID
        lockNote.isHidden = true

        let autoTitle = Kit.title("Auto", tip: "Follow the camera path: the view tracks the keyframes at the playhead.")
        let analysisTitle = Kit.title("Analysis", tip: "Detects people and objects; needed to build a camera path.")
        let pathTitle = Kit.title("Camera path", tip: "How the path is generated from the detections.")
        let stabTitle = Kit.title("Stabilise", tip: "Horizon lock and shake removal from the camera's motion data.")

        let stack = Kit.sidebarStack(in: view, [
            autoTitle, autoButton,
            analysisTitle, qualityPopup, progress, cancelButton, analyseButton, buildButton, reanalyseButton, detectionsCheck,
            pathTitle, stylePopup, forwardPopup, lockCheck, lockNote,
            stabTitle, stabilizePopup,
        ])
        for v in [autoButton, reanalyseButton, detectionsCheck, lockCheck, lockNote, stabilizePopup] { stack.setCustomSpacing(18, after: v) }
        stack.setCustomSpacing(6, after: qualityPopup)
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

        detectionsCheck.state = model.showDetections ? .on : .off
        detectionsCheck.isEnabled = analysed

        qualityPopup.selectItem(at: AnalysisQuality.allCases.firstIndex(of: model.analysisQuality) ?? 0)
        qualityPopup.isEnabled = busy == nil
        stylePopup.selectItem(at: PathStyle.allCases.firstIndex(of: model.style) ?? 0)
        let travel = model.travelEstimate?.isUsable == true
        forwardPopup.selectItem(at: TravelDirection.ForwardMode.allCases.firstIndex(of: travel ? model.forwardMode : .cameraFront) ?? 0)
        forwardPopup.isEnabled = travel && model.style == .scenery && !model.directionLock
        forwardPopup.toolTip = "Where the Scenery shots that look straight ahead are aimed: along the direction of travel (accelerometer and GPS; needs movement and GPS) or straight ahead of the camera. Used by the Scenery style only. " + model.forwardNote
        lockCheck.state = model.directionLock ? .on : .off
        lockCheck.isEnabled = model.duration > 0
        lockNote.stringValue = DirectionLock.summary(yaw: model.lockedYaw)
        lockNote.isHidden = !model.directionLock
        stabilizePopup.selectItem(at: StabilizeMode.allCases.firstIndex(of: model.stabilization) ?? 0)
    }

    @objc private func autoToggled() { model.autoFollow = autoButton.state == .on && !model.keyframes.isEmpty }
    @objc private func detectionsToggled() { model.showDetections = detectionsCheck.state == .on }
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

    @objc private func qualityChosen() {
        model.analysisQuality = AnalysisQuality.allCases[max(qualityPopup.indexOfSelectedItem, 0)]
    }

    @objc private func styleChosen() {
        model.style = PathStyle.allCases[stylePopup.indexOfSelectedItem]
        model.styleChanged()
    }

    @objc private func forwardChosen() {
        model.setForwardMode(TravelDirection.ForwardMode.allCases[max(forwardPopup.indexOfSelectedItem, 0)])
    }

    @objc private func lockToggled() { model.setDirectionLock(lockCheck.state == .on) }

    @objc private func stabilizeChosen() {
        model.stabilization = StabilizeMode.allCases[stabilizePopup.indexOfSelectedItem]
        model.stabilizationChanged()
    }
}
