import Foundation

/// `--batch-run [--out DIR] [--force] [--no-export] [--style follow|scenery] [--quality fast|medium|best] [--settings JSON] FILE_OR_FOLDER...`
/// Runs the same engine as the batch window without UI. Settings are not saved. Exits 0 when every item succeeded.
enum BatchCLI {
    static func run(args: [String]) -> Never {
        var settings = BatchSettings()
        var inputs: [URL] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "--out": settings.outputFolder = next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--force": settings.forceReanalyse = true
            case "--no-export": settings.export = false
            case "--style": settings.style = next() == "scenery" ? .scenery : .follow
            case "--forward": settings.forwardMode = next() == "front" ? .cameraFront : .travelDirection
            case "--quality": settings.analysisQuality = next().flatMap { q in AnalysisQuality.allCases.first { $0.rawValue.lowercased().hasPrefix(q.lowercased()) } } ?? .fast
            case "--settings":
                if let json = next(), let s = try? JSONDecoder().decode(ExportSettings.self, from: Data(json.utf8)) { settings.exportSettings = s }
            default: inputs.append(URL(fileURLWithPath: a))
            }
            i += 1
        }
        Task { @MainActor in
            let runner = BatchRunner(settings: settings, persist: false)
            let n = runner.add(inputs)
            print("batch: \(n) file(s)"); fflush(stdout)
            if let problem = runner.start() { print("batch: \(problem)"); exit(2) }
            await runner.wait()
            var failed = 0
            for item in runner.queue.items {
                switch item.state {
                case .failed(let m): failed += 1; print("FAILED \(item.url.lastPathComponent): \(m)")
                default: print("done \(item.url.lastPathComponent)\(item.output.map { " -> " + $0.path } ?? "")")
                }
            }
            fflush(stdout)
            exit(failed == 0 ? 0 : 1)
        }
        dispatchMain()
    }
}
