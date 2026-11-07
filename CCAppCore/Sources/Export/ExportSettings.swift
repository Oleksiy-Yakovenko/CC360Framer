import AVFoundation
import Foundation

/// Everything the user can choose about the exported file. Plain value type: saved as app-wide defaults (UserDefaults)
/// and per file in the project sidecar. Decoding is lenient (missing or unknown values fall back to the defaults) so
/// files written by older or newer versions keep loading.
struct ExportSettings: Codable, Equatable {
    enum Container: String, Codable, CaseIterable {
        case mp4, mov
        var fileExtension: String { rawValue }
        var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
        var label: String { self == .mp4 ? "MP4" : "MOV" }
    }
    enum Codec: String, Codable, CaseIterable {
        case hevc, h264
        var avCodec: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
        var label: String { self == .hevc ? "HEVC (H.265)" : "H.264" }
    }
    enum RateControl: String, Codable, CaseIterable {
        case bitrate, quality
        var label: String { self == .bitrate ? "Bitrate" : "Quality" }
    }
    /// Short side of the output in pixels (1080 = "1080p"), or an explicit width.
    enum Resolution: String, Codable, CaseIterable {
        case p720 = "720p", p1080 = "1080p", p1440 = "1440p", p2160 = "4K", custom
        var shortSide: Int? {
            switch self {
            case .p720: return 720
            case .p1080: return 1080
            case .p1440: return 1440
            case .p2160: return 2160
            case .custom: return nil
            }
        }
        var label: String { self == .custom ? "Custom width" : rawValue }
    }
    enum Aspect: String, Codable, CaseIterable {
        case a16x9 = "16:9", a9x16 = "9:16", a1x1 = "1:1", a4x5 = "4:5", a4x3 = "4:3", custom
        var ratio: (w: Int, h: Int)? {
            switch self {
            case .a16x9: return (16, 9)
            case .a9x16: return (9, 16)
            case .a1x1: return (1, 1)
            case .a4x5: return (4, 5)
            case .a4x3: return (4, 3)
            case .custom: return nil
            }
        }
        var label: String { self == .custom ? "Custom" : rawValue }
    }

    var container: Container = .mp4
    var codec: Codec = .hevc
    var rateControl: RateControl = .bitrate
    /// nil = automatic: 20 Mbps up to ~3 MP, 50 Mbps above (the original preset values).
    var bitrateMbps: Double?
    /// 0...1 for `.quality`.
    var quality: Double = 0.7
    var resolution: Resolution = .p1080
    var customWidth: Int = 1920
    var aspect: Aspect = .a16x9
    var customAspectW: Int = 16
    var customAspectH: Int = 9
    /// Cross-dissolve length at cuts in seconds (used by the cut feature).
    var crossfade: Double = 0.5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func get<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? d }
        container = get(.container, container); codec = get(.codec, codec); rateControl = get(.rateControl, rateControl)
        bitrateMbps = (try? c.decodeIfPresent(Double.self, forKey: .bitrateMbps)) ?? nil
        quality = get(.quality, quality); resolution = get(.resolution, resolution); customWidth = get(.customWidth, customWidth)
        aspect = get(.aspect, aspect); customAspectW = get(.customAspectW, customAspectW); customAspectH = get(.customAspectH, customAspectH)
        crossfade = get(.crossfade, crossfade)
    }

    /// Width : height of the output.
    var aspectRatio: (w: Int, h: Int) {
        let r = aspect.ratio ?? (customAspectW, customAspectH)
        return (max(r.w, 1), max(r.h, 1))
    }

    /// Output aspect as a number (width / height).
    var aspectValue: Double { Double(aspectRatio.w) / Double(aspectRatio.h) }

    /// Output pixel size, both dimensions even (encoders need that). Preset resolutions fix the short side; a custom
    /// resolution fixes the width.
    var outputSize: (width: Int, height: Int) {
        let r = aspectRatio
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if let s = resolution.shortSide {
            let sd = Double(s)
            return r.w >= r.h ? (even(sd * Double(r.w) / Double(r.h)), even(sd)) : (even(sd), even(sd * Double(r.h) / Double(r.w)))
        }
        let w = Double(min(max(customWidth, 16), 8192))
        return (even(w), even(w * Double(r.h) / Double(r.w)))
    }

    /// Effective average bitrate in bits per second for `.bitrate`.
    var bitRate: Int {
        if let m = bitrateMbps, m > 0 { return Int(m * 1_000_000) }
        let s = outputSize
        return s.width * s.height > 3_000_000 ? 50_000_000 : 20_000_000
    }

    /// Compression properties for the video input.
    var compressionProperties: [String: Any] {
        switch rateControl {
        case .bitrate: return [AVVideoAverageBitRateKey: bitRate]
        case .quality: return [AVVideoQualityKey: min(max(quality, 0), 1)]
        }
    }

    var videoOutputSettings: [String: Any] {
        let s = outputSize
        return [AVVideoCodecKey: codec.avCodec, AVVideoWidthKey: s.width, AVVideoHeightKey: s.height,
                AVVideoCompressionPropertiesKey: compressionProperties]
    }

    static let audioBitRate = 192_000

    // MARK: persistence of the app-wide default

    static let defaultsKey = "exportSettings"

    static func loadDefaults(_ d: UserDefaults = .standard) -> ExportSettings {
        guard let data = d.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(ExportSettings.self, from: data) else { return ExportSettings() }
        return s
    }

    func saveDefaults(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }
}
