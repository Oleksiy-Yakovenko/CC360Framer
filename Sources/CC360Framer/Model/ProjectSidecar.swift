import Foundation

/// Per-file settings saved in the `project` sidecar. Every field is optional so that files written by older versions
/// keep loading and later features can add their own (cuts, cards, captions) without breaking this one.
struct ProjectSidecar: Codable, Equatable {
    var locationStyle: LocationCardStyle?
    var locationPlacement: OverlayPlacement?
    var exportSettings: ExportSettings?
    var globalFov: GlobalFov?
    /// Removed stretches of the source video (nil = none).
    var cuts: [CutRegion]?
    /// Preview playback skips the cuts (nil = off).
    var previewWithCuts: Bool?
    /// Location card keyframes (nil = none, then the automatic card applies).
    var locationCards: [LocationCardKey]?
    /// false = no automatic card at t = 0 (nil = on).
    var autoLocationCard: Bool?
    /// false = no location card at all (nil = on).
    var showLocationCard: Bool?
    /// Parts of the place shown on the card (nil = defaults).
    var locationFields: LocationCardFields?
    /// Captions (source time) and the global caption style for this file (nil = none / app default).
    var captions: [Caption]?
    var captionStyle: CaptionStyle?
    /// Where Scenery "forward" shots look (nil = the app default).
    var forwardMode: TravelDirection.ForwardMode?
    /// Direction lock (nil = off) and the last direction the user set, yaw in radians (nil = 0, camera front).
    var directionLock: Bool?
    var lockedYaw: Float?

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
