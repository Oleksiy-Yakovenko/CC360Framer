import Foundation

/// Per-file settings saved in the `project` sidecar. Every field is optional so that files written by older versions
/// keep loading and later features can add their own (cuts, cards, captions) without breaking this one.
struct ProjectSidecar: Codable, Equatable {
    var locationStyle: LocationCardStyle?
    var locationPlacement: OverlayPlacement?
    var exportSettings: ExportSettings?

    static let kind = "project"

    /// Empty project when there is no file or it cannot be read.
    static func load(for video: URL) -> ProjectSidecar {
        guard let data = Sidecar.read(for: video, kind: kind) else { return ProjectSidecar() }
        return decode(data) ?? ProjectSidecar()
    }

    static func decode(_ data: Data) -> ProjectSidecar? { try? JSONDecoder().decode(ProjectSidecar.self, from: data) }

    func encoded() -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(self)
    }

    func save(for video: URL) {
        if let data = encoded() { Sidecar.write(data, for: video, kind: Self.kind) }
    }
}
