import Foundation

/// Optional global field of view that replaces the fov of every keyframe, in preview, export and batch.
struct GlobalFov: Codable, Equatable {
    static let range: ClosedRange<Float> = 20...140

    var enabled = false
    /// Vertical field of view in degrees.
    var degrees: Float = 70

    init(enabled: Bool = false, degrees: Float = 70) { self.enabled = enabled; self.degrees = degrees }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        degrees = (try? c.decodeIfPresent(Float.self, forKey: .degrees)) ?? 70
    }

    /// The fov to use for a path/view value `fov`: the global one when enabled, otherwise `fov` unchanged.
    func resolve(_ fov: Float) -> Float {
        enabled ? min(max(degrees, Self.range.lowerBound), Self.range.upperBound) : fov
    }

    static let defaultsKey = "globalFov"

    static func loadDefaults(_ d: UserDefaults = .standard) -> GlobalFov {
        guard let data = d.data(forKey: defaultsKey), let g = try? JSONDecoder().decode(GlobalFov.self, from: data) else { return GlobalFov() }
        return g
    }

    func saveDefaults(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }
}

extension CameraPath {
    /// The single place where the camera path is sampled for display or export: applies the global fov override.
    /// `fallback` is used when the path has no keyframes.
    func sample(at t: Double, global: GlobalFov, fallback: (yaw: Float, pitch: Float, fov: Float)) -> (yaw: Float, pitch: Float, fov: Float) {
        let cam = sample(at: t) ?? fallback
        return (cam.yaw, cam.pitch, global.resolve(cam.fov))
    }
}
