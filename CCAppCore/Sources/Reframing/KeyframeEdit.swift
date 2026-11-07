import Foundation

/// Editing one keyframe from the Inspector (values in degrees / seconds).
enum KeyframeEdit {
    struct Values: Equatable {
        var time: Double
        var yaw: Double
        var pitch: Double
        var fov: Double

        init(time: Double, yaw: Double, pitch: Double, fov: Double) { self.time = time; self.yaw = yaw; self.pitch = pitch; self.fov = fov }

        init(_ k: Keyframe) {
            self.init(time: k.time, yaw: Double(k.yaw) * 180 / .pi, pitch: Double(k.pitch) * 180 / .pi, fov: Double(k.fov))
        }
    }

    /// Keys closer than this are rejected (the path interpolates between neighbours and needs distinct times).
    static let minSpacing = 0.05
    static let pitchLimit = 85.0
    static let fovRange = 20.0...140.0

    /// Keys with `id` set to `values` (time clamped to the clip, yaw wrapped to -180...180, pitch and fov clamped to
    /// what the camera allows), sorted by time. nil when `id` is unknown, a value is not finite, or the new time
    /// would sit on top of another keyframe.
    static func apply(_ keys: [Keyframe], id: UUID, _ v: Values, duration: Double) -> [Keyframe]? {
        guard let i = keys.firstIndex(where: { $0.id == id }),
              [v.time, v.yaw, v.pitch, v.fov].allSatisfy(\.isFinite) else { return nil }
        let time = max(0, duration > 0 ? min(v.time, duration) : v.time)
        if keys.enumerated().contains(where: { $0.offset != i && abs($0.element.time - time) < minSpacing }) { return nil }
        var yaw = v.yaw.truncatingRemainder(dividingBy: 360)
        if yaw > 180 { yaw -= 360 } else if yaw <= -180 { yaw += 360 }
        var out = keys
        out[i] = Keyframe(id: id, time: time, yaw: Float(yaw * .pi / 180),
                          pitch: Float(max(-pitchLimit, min(pitchLimit, v.pitch)) * .pi / 180),
                          fov: Float(max(fovRange.lowerBound, min(fovRange.upperBound, v.fov))))
        return out.sorted { $0.time < $1.time }
    }
}
