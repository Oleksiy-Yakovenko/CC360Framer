import AVFoundation
import Foundation

/// What is known about an audio file chosen for a clip.
struct AudioFileInfo: Equatable, Sendable {
    var exists: Bool
    /// Seconds; nil when unknown (file missing or unreadable).
    var duration: Double?
    var hasAudio: Bool

    var isUsable: Bool { exists && hasAudio }

    /// Short problem text for the Inspector; nil when the file is fine.
    var problem: String? {
        if !exists { return "File not found" }
        if !hasAudio { return "No audio track in this file" }
        return nil
    }
}

/// Pure helpers for the Inspector's audio page.
enum AudioFileLogic {
    /// Start position inside the file: never negative, and not beyond the file's end when its duration is known.
    static func clampOffset(_ offset: Double, fileDuration: Double?) -> Double {
        guard offset.isFinite else { return 0 }
        var v = max(0, offset)
        if let d = fileDuration, d.isFinite, d >= 0 { v = min(v, d) }
        return v
    }

    /// "1:05.3" style length for the tooltip; seconds below a minute stay "12.5 s".
    static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "?" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let m = Int(seconds) / 60
        return String(format: "%d:%04.1f", m, seconds - Double(m * 60))
    }

    /// Volume 0...1 <-> slider percent 0...100.
    static func percent(fromVolume v: Double) -> Double { (max(0, min(1, v)) * 100).rounded() }
    static func volume(fromPercent p: Double) -> Double { max(0, min(1, p / 100)) }
}

enum AudioFileProbe {
    /// Opens the file with AVFoundation and reports whether it has an audio track and how long it is. Never throws:
    /// a missing, unreadable or non-audio file gives `exists`/`hasAudio` false. The asset lives only inside this call,
    /// so nothing non-Sendable crosses an isolation boundary.
    static func probe(_ url: URL) async -> AudioFileInfo {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            return AudioFileInfo(exists: false, duration: nil, hasAudio: false)
        }
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { return AudioFileInfo(exists: true, duration: nil, hasAudio: false) }
            let d = try await asset.load(.duration).seconds
            return AudioFileInfo(exists: true, duration: d.isFinite ? d : nil, hasAudio: true)
        } catch {
            return AudioFileInfo(exists: true, duration: nil, hasAudio: false)
        }
    }
}

/// Per-path cache of probe results, so views can ask on every refresh without re-probing. Main actor only; the probe
/// itself runs off the main thread (async, nonisolated) and the result hops back here.
@MainActor
final class AudioProbeCache {
    private var results: [String: AudioFileInfo] = [:]
    private var pending: Set<String> = []
    /// Called on the main actor when a new result arrived.
    var onChange: (() -> Void)?

    /// The cached result, or nil while it is being probed (a probe is started if none is running).
    func info(for path: String) -> AudioFileInfo? {
        guard !path.isEmpty else { return nil }
        if let r = results[path] { return r }
        if pending.insert(path).inserted {
            Task { @MainActor [weak self] in
                let r = await AudioFileProbe.probe(URL(fileURLWithPath: path))
                guard let self else { return }
                self.pending.remove(path)
                self.results[path] = r
                self.onChange?()
            }
        }
        return nil
    }

    /// Forget a path so the next `info(for:)` probes again (after Browse, or when the user retypes the same path).
    func invalidate(_ path: String) { results[path] = nil }
}
