import Foundation

/// Runs the `BatchQueue` sequentially in the background. Observable so the batch window can refresh.
@MainActor
final class BatchRunner: ObservableObject {
    @Published private(set) var queue = BatchQueue()
    @Published var settings: BatchSettings { didSet { if persist, settings != oldValue { settings.save() } } }
    private let persist: Bool

    init(settings: BatchSettings = BatchSettings.load(), persist: Bool = true) {
        self.settings = settings
        self.persist = persist
    }
    private var task: Task<Void, Never>?
    private var cancel = CancelFlag()
    /// Called on the main actor when the loop ends (finished, or paused).
    var onStop: (() -> Void)?

    // MARK: List editing (forwarded so every change notifies the observers)

    @discardableResult func add(_ urls: [URL]) -> Int { var q = queue; let n = q.add(urls); queue = q; return n }
    func remove(_ ids: Set<UUID>) { queue.remove(ids) }
    func clear() { queue.clear() }
    func removeFinished() { queue.removeFinished() }
    func move(from offsets: IndexSet, to destination: Int) { queue.move(from: offsets, to: destination) }

    var progress: Double { queue.overallProgress(export: settings.export) }

    // MARK: Control

    /// Starts or resumes. Returns a message when it cannot start.
    @discardableResult
    func start() -> String? {
        if let problem = settings.startProblem { return problem }
        if queue.runState == .pausing { _ = queue.start(); objectWillChange.send(); return nil }
        guard queue.start() else { return queue.items.isEmpty ? "The list is empty." : "Nothing left to process." }
        cancel = CancelFlag()
        task = Task { [weak self] in await self?.loop() }
        return nil
    }

    /// The current item finishes, then the queue stops.
    func pause() { queue.pause() }

    /// Aborts the running item (used when the app quits or on "Stop").
    func abort() { queue.pause(); cancel.set() }

    private func loop() async {
        while let id = queue.beginNext() {
            guard let item = queue.items.first(where: { $0.id == id }) else { continue }
            var options = BatchJob.Options()
            options.forceReanalyse = settings.forceReanalyse
            options.export = settings.export
            options.style = settings.style
            options.forwardMode = settings.forwardMode
            options.analysisQuality = settings.analysisQuality
            options.exportSettings = settings.exportSettings
            var output: URL?
            if settings.export, let folder = settings.outputFolder {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                output = BatchQueue.outputURL(for: item.url, in: folder, ext: settings.exportSettings.container.fileExtension, taken: queue.takenOutputs)
                queue.setOutput(id, output)
            }
            let flag = cancel
            do {
                try await BatchJob.run(url: item.url, options: options, output: output, cancel: flag) { [weak self] state in
                    Task { @MainActor in
                        guard let self, let i = self.queue.index(of: id), self.queue.items[i].state.isActive else { return }
                        self.queue.setState(id, state)
                    }
                }
                queue.setState(id, .done)
            } catch {
                queue.setState(id, .failed(error is CancellationError ? "Cancelled" : error.localizedDescription))
            }
        }
        task = nil
        onStop?()
    }

    /// Waits until the loop ended (headless runs).
    func wait() async { await task?.value }
}
