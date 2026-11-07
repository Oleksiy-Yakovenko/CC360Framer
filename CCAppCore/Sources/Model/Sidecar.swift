import Foundation

/// Locations of the per-video sidecar files. They live in `CC360Framer.sidecars` next to the video and are named
/// `<video file name>.<kind>.json` (kind: `reframe`, `analysis`, `location`, `project`).
enum Sidecar {
    static let folderName = "CC360Framer.sidecars"

    /// Where a sidecar is written. Does not touch the disk.
    static func url(for video: URL, kind: String) -> URL {
        video.deletingLastPathComponent().appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(video.lastPathComponent + "." + kind + ".json")
    }

    /// The pre-folder location next to the video (read-only fallback).
    static func legacyURL(for video: URL, kind: String) -> URL { video.appendingPathExtension(kind + ".json") }

    /// Where to read from: the folder file if present, else the legacy file next to the video, else the folder path.
    static func readURL(for video: URL, kind: String) -> URL {
        let new = url(for: video, kind: kind)
        let fm = FileManager.default
        if fm.fileExists(atPath: new.path) { return new }
        let old = legacyURL(for: video, kind: kind)
        return fm.fileExists(atPath: old.path) ? old : new
    }

    static func read(for video: URL, kind: String) -> Data? { try? Data(contentsOf: readURL(for: video, kind: kind)) }

    /// Writes into the sidecar folder, creating it first.
    @discardableResult
    static func write(_ data: Data, for video: URL, kind: String) -> Bool {
        let dest = url(for: video, kind: kind)
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: dest)
            return true
        } catch { return false }
    }
}
