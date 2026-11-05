import SwiftUI
import MetalKit
import UniformTypeIdentifiers

struct MetalView: NSViewRepresentable {
    let model: PlayerModel

    func makeNSView(context: Context) -> LookView {
        let device = MTLCreateSystemDefaultDevice()!
        let view = LookView(frame: .zero, device: device)
        view.state = model.viewState
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        let renderer = try! Renderer(device: device, state: model.viewState, pixelFormat: view.colorPixelFormat)
        renderer.frameProvider = { [frames = model.frames] in frames.next() }
        renderer.preDraw = { [weak model] in MainActor.assumeIsolated { model?.applyPath() } }
        view.delegate = renderer
        context.coordinator.renderer = renderer
        return view
    }

    func updateNSView(_ nsView: LookView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: Renderer? }
}

struct ContentView: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                MetalView(model: model)
                if let err = model.errorText {
                    Text(err).padding().background(.red.opacity(0.8)).foregroundStyle(.white).cornerRadius(8)
                }
            }
            .frame(minHeight: 300)
            controls.padding(10)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in await model.open(url) } }
            }
            return true
        }
    }

    @State private var preset = Exporter.Preset.all[0]

    var controls: some View {
        VStack(spacing: 6) {
            HStack {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 20)
                }
                .keyboardShortcut(.space, modifiers: [])
                Text(format(model.position)).monospacedDigit()
                VStack(spacing: 0) {
                    Slider(value: Binding(get: { model.position }, set: { model.scrub(to: $0) }),
                           in: 0...max(model.duration, 0.1),
                           onEditingChanged: { editing in
                               if editing { model.beginScrub() } else { model.endScrub(at: model.position) }
                           })
                    keyTicks.frame(height: 12)
                }
                Text(format(model.duration)).monospacedDigit()
            }
            HStack {
                Toggle("Auto", isOn: Binding(get: { model.autoFollow }, set: { model.autoFollow = $0 && !model.keyframes.isEmpty }))
                    .toggleStyle(.button).disabled(model.keyframes.isEmpty)
                    .help("Follow the camera path")
                if let p = model.analysisProgress {
                    ProgressView(value: p).frame(width: 90)
                    Button("Cancel") { model.cancelJob() }
                } else {
                    Button("Analyse") { model.analyze() }.help("Find the subject and build a camera path")
                }
                Button("Set key") { model.setKey() }.keyboardShortcut("k", modifiers: [])
                    .help("Keyframe the current view at the playhead (K)")
                Button("Delete key") { model.deleteSelectedKey() }.disabled(model.selectedKey == nil)
                    .keyboardShortcut(.delete, modifiers: [])
                Button("Clear keys") { model.clearKeys() }.disabled(model.keyframes.isEmpty)
                Spacer()
                if let p = model.exportProgress {
                    ProgressView(value: p).frame(width: 90)
                    Button("Cancel") { model.cancelJob() }
                } else {
                    Picker("", selection: $preset) {
                        ForEach(Exporter.Preset.all, id: \.self) { Text($0.name).tag($0) }
                    }.labelsHidden().frame(width: 140)
                    Button("Export…") { exportPanel() }.disabled(model.duration == 0)
                }
            }
            HStack {
                Button("Open…") { openPanel() }
                Text(model.statusText ?? model.title).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                if !model.audioOptions.isEmpty {
                    Image(systemName: "speaker.wave.2")
                    ForEach(model.audioOptions) { opt in
                        Toggle(opt.label, isOn: Binding(get: { opt.enabled }, set: { _ in model.toggleAudio(opt.id) }))
                            .toggleStyle(.button)
                    }
                }
            }
        }
    }

    /// Keyframe markers aligned under the seekbar; click one to select it and jump there.
    var keyTicks: some View {
        GeometryReader { geo in
            let inset: CGFloat = 8   // slider thumb radius
            let width = max(geo.size.width - inset * 2, 1)
            ForEach(model.keyframes) { key in
                let selected = key.id == model.selectedKey
                Image(systemName: "diamond.fill")
                    .font(.system(size: selected ? 10 : 7))
                    .foregroundStyle(selected ? Color.accentColor : Color.orange)
                    .frame(width: 14, height: 12)
                    .contentShape(Rectangle())
                    .position(x: inset + width * CGFloat(key.time / max(model.duration, 0.1)), y: 6)
                    .onTapGesture { model.select(key) }
            }
        }
    }

    func exportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = (model.title as NSString).deletingPathExtension + "-reframed.mp4"
        if panel.runModal() == .OK, let url = panel.url { model.export(preset: preset, to: url) }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "360") ?? .movie, .movie, .mpeg4Movie]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.open(url) }
        }
    }

    func format(_ s: Double) -> String {
        let t = Int(max(s, 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct CC360FramerApp: App {
    @StateObject private var model = PlayerModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("CC360Framer") {
            ContentView(model: model)
                .task {
                    // First non-flag argument is a file to open on launch.
                    if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                        await model.open(URL(fileURLWithPath: path))
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.cleanup()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { NSApp.sendAction(#selector(NSDocumentController.openDocument(_:)), to: nil, from: nil) }
                    .keyboardShortcut("o")
            }
        }
    }
}
