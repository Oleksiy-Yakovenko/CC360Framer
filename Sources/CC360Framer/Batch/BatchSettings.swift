import Foundation

/// Options of a batch run; persisted in `UserDefaults` (`batchSettings`), separate from the interactive export defaults.
struct BatchSettings: Codable, Equatable {
    /// Analyse again even when an analysis sidecar exists (and rebuild the path, replacing existing keyframes).
    var forceReanalyse = false
    /// Export the videos; off = only analysis and path building (keyframes are saved next to the video).
    var export = true
    var style: PathStyle = .follow
    /// Views used when a file is analysed.
    var analysisQuality: AnalysisQuality = .fast
    /// Folder for the exported videos. Never defaults to the footage folder: it must be chosen before an export starts.
    var outputFolder: URL?
    /// Replaces the per-file export settings for the whole run. Starts as the app's default export settings.
    var exportSettings = ExportSettings.loadDefaults()

    static let defaultsKey = "batchSettings"

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        forceReanalyse = (try? c.decodeIfPresent(Bool.self, forKey: .forceReanalyse)) ?? false
        export = (try? c.decodeIfPresent(Bool.self, forKey: .export)) ?? true
        style = ((try? c.decodeIfPresent(String.self, forKey: .style)) ?? nil).flatMap { PathStyle(rawValue: $0) } ?? .follow
        analysisQuality = AnalysisQuality(stored: (try? c.decodeIfPresent(String.self, forKey: .analysisQuality)) ?? nil)
        outputFolder = (try? c.decodeIfPresent(String.self, forKey: .outputFolder)).flatMap { $0 }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        exportSettings = (try? c.decodeIfPresent(ExportSettings.self, forKey: .exportSettings)) ?? ExportSettings.loadDefaults()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(forceReanalyse, forKey: .forceReanalyse)
        try c.encode(export, forKey: .export)
        try c.encode(style.rawValue, forKey: .style)
        try c.encode(analysisQuality.rawValue, forKey: .analysisQuality)
        try c.encodeIfPresent(outputFolder?.path, forKey: .outputFolder)
        try c.encode(exportSettings, forKey: .exportSettings)
    }

    private enum CodingKeys: String, CodingKey { case forceReanalyse, export, style, analysisQuality, outputFolder, exportSettings }

    static func load(_ d: UserDefaults = .standard) -> BatchSettings {
        guard let data = d.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(BatchSettings.self, from: data) else { return BatchSettings() }
        return s
    }

    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }

    /// Why the run cannot start, or nil.
    var startProblem: String? {
        if export, outputFolder == nil { return "Choose an output folder first." }
        return nil
    }
}
