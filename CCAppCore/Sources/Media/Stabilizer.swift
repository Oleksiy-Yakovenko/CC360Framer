import Foundation
import simd

enum StabilizeMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case level = "Level"
    case smooth = "Level + smooth"
    var id: String { rawValue }
}

/// A virtual camera that stays level with the horizon and (optionally) turns smoothly, built from
/// the recorded orientation. `basis(at:)` gives the columns (right, up, forward) of that camera
/// expressed in the camera body's axes, so a direction in the virtual view maps to the body
/// frame (the one the video is stored in) as `right * x + up * y + forward * z`.
final class Stabilizer {
    struct Basis {
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var forward: SIMD3<Float>
        static let identity = Basis(right: [1, 0, 0], up: [0, 1, 0], forward: [0, 0, 1])
    }

    /// Sensor axes -> render axes (x right, y up, z front), found by checking horizon level on
    /// frames with strong roll and pitch (gravity reads +y when upright, i.e. pointing down).
    /// It mirrors x, so rotation axes need the extra determinant sign below.
    nonisolated(unsafe) static var sensorToRender = SIMD3<Float>(1, -1, 1)

    /// How to treat IORI, the image-vs-body rotation. The camera has already rotated the stored image by it
    /// (roll correction), so sampling directions must be rotated by it too: measured 30% less residual shake
    /// than ignoring it, while the opposite sign is worse.
    enum IORI { case ignore, forward, inverse }
    nonisolated(unsafe) static var iori: IORI = .forward

    /// Where the horizon (up vector) comes from: the per-frame gravity vector, or the gyro-integrated orientation
    /// anchored to a heavily smoothed gravity (immune to accelerometer noise from engine vibration).
    enum UpSource { case gravity, orientation }
    nonisolated(unsafe) static var upSource: UpSource = .orientation
    /// Gravity smoothing for `.orientation` (seconds).
    static let anchorSeconds: Float = 2.0

    /// Heading smoothing (seconds, gaussian sigma) for `.smooth`.
    nonisolated(unsafe) static var smoothingSeconds: Float = 0.7

    private var bases: [Basis]
    private let rate: Double

    init(telemetry: Telemetry, duration: Double, mode: StabilizeMode) {
        let n = telemetry.count
        rate = Double(n) / max(duration, 0.001)
        guard mode != .off else { bases = [.identity]; return }
        let map = Self.sensorToRender

        // Body-frame "up" per frame, lightly smoothed (3-tap) to take the edge off sensor noise.
        let rawUp = telemetry.gravity.prefix(n).map { simd_normalize(-($0 * map)) }
        // Orientation quaternions in render axes. Axes are pseudovectors: mapping them through a
        // reflection S gives det(S) * S * axis.
        let det = map.x * map.y * map.z
        let q: [simd_quatf] = telemetry.orientation.prefix(n).map {
            simd_normalize(simd_quatf(ix: det * $0.y * map.x, iy: det * $0.z * map.y, iz: det * $0.w * map.z, r: $0.x))
        }
        var up: [SIMD3<Float>] = (0..<n).map { (i: Int) -> SIMD3<Float> in
            let prev: SIMD3<Float> = rawUp[max(i - 1, 0)]
            let next: SIMD3<Float> = rawUp[min(i + 1, n - 1)]
            let sum: SIMD3<Float> = prev + rawUp[i] * 2 + next
            return simd_normalize(sum)
        }
        if Self.upSource == .orientation {
            // Gravity expressed in the start frame is constant for a rigid world: average it over seconds,
            // then rotate it back into the body with the (gyro-integrated) orientation at every frame.
            let world = (0..<n).map { q[$0].inverse.act(rawUp[$0]) }
            let sigma = Float(rate) * Self.anchorSeconds
            let wx = Gaussian.smooth(world.map { $0.x }, sigma: sigma)
            let wy = Gaussian.smooth(world.map { $0.y }, sigma: sigma)
            let wz = Gaussian.smooth(world.map { $0.z }, sigma: sigma)
            up = (0..<n).map { (i: Int) -> SIMD3<Float> in
                let dir: SIMD3<Float> = simd_normalize(SIMD3<Float>(wx[i], wy[i], wz[i]))
                return simd_normalize(q[i].act(dir))
            }
        }

        var headings = [SIMD3<Float>](repeating: [0, 0, 1], count: n)
        if mode == .smooth {
            // Heading of the body's forward axis in the start frame, on the plane perpendicular to the
            // average start-frame up; unwrap, smooth, then rebuild forward vectors.
            let up0: [SIMD3<Float>] = (0..<n).map { q[$0].inverse.act(up[$0]) }
            let ref = simd_normalize(up0.reduce(.zero, +))
            let e1 = simd_normalize(simd_cross(abs(ref.y) < 0.9 ? [0, 1, 0] : [1, 0, 0], ref))
            let e2 = simd_cross(ref, e1)
            var psi = (0..<n).map { i -> Float in
                let f = q[i].inverse.act([0, 0, 1])
                return atan2(simd_dot(f, e2), simd_dot(f, e1))
            }
            for i in 1..<max(n, 1) { psi[i] = psi[i - 1] + wrapAngle(psi[i] - psi[i - 1]) }
            let smoothed = Gaussian.smooth(psi, sigma: Float(rate) * Self.smoothingSeconds)
            for i in 0..<n {
                let f0 = cos(smoothed[i]) * e1 + sin(smoothed[i]) * e2
                headings[i] = q[i].act(f0)
            }
        }

        let correction: [simd_quatf?] = (0..<n).map { i in
            guard Self.iori != .ignore, i < telemetry.imageOrientation.count else { return nil }
            let r = telemetry.imageOrientation[i], det = map.x * map.y * map.z
            let qi = simd_normalize(simd_quatf(ix: det * r.y * map.x, iy: det * r.z * map.y, iz: det * r.w * map.z, r: r.x))
            return Self.iori == .forward ? qi : qi.inverse
        }
        bases = (0..<n).map { i in
            let u = up[i]
            var f = headings[i] - simd_dot(headings[i], u) * u
            if simd_length(f) < 1e-4 { f = [0, 0, 1] - u.z * u }
            f = simd_normalize(f)
            var b = Basis(right: simd_cross(u, f), up: u, forward: f)
            if let c = correction[i] { b = Basis(right: c.act(b.right), up: c.act(b.up), forward: c.act(b.forward)) }
            return b
        }
    }

    /// Linear blend between the two nearest frames' cameras (re-orthonormalised), so sub-frame times are exact.
    func basis(at time: Double) -> Basis {
        if bases.count == 1 { return bases[0] }
        let f = min(max(time * rate, 0), Double(bases.count - 1))
        let i = min(Int(f), bases.count - 2), w = Float(f - Double(i))
        let a = bases[i], b = bases[i + 1]
        let up = simd_normalize(a.up * (1 - w) + b.up * w)
        var fw = a.forward * (1 - w) + b.forward * w
        fw = simd_normalize(fw - simd_dot(fw, up) * up)
        return Basis(right: simd_cross(up, fw), up: up, forward: fw)
    }

    /// Direction in the virtual camera (yaw/pitch) -> yaw/pitch in the body's axes (the video's frame) at `time`.
    func toBody(yaw: Float, pitch: Float, at time: Double) -> (yaw: Float, pitch: Float) {
        let b = basis(at: time)
        let v = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let d = b.right * v.x + b.up * v.y + b.forward * v.z
        return (atan2(d.x, d.z), asin(max(-1, min(1, d.y))))
    }

    /// Direction seen by the body (yaw/pitch in body axes) -> yaw/pitch in the virtual camera at `time`.
    func toVirtual(yaw: Float, pitch: Float, at time: Double) -> (yaw: Float, pitch: Float) {
        let b = basis(at: time)
        let d = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let v = SIMD3<Float>(simd_dot(d, b.right), simd_dot(d, b.up), simd_dot(d, b.forward))
        return (atan2(v.x, v.z), asin(max(-1, min(1, v.y))))
    }
}

enum Gaussian {
    /// Zero-phase gaussian smoothing with edge renormalisation (sigma in samples).
    static func smooth(_ a: [Float], sigma: Float) -> [Float] {
        guard sigma > 0.01, !a.isEmpty else { return a }
        let r = Int(sigma * 2.5)
        let kernel = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        return (0..<a.count).map { i in
            var sum: Float = 0, wsum: Float = 0
            for k in -r...r where i + k >= 0 && i + k < a.count {
                let w = kernel[k + r]; sum += w * a[i + k]; wsum += w
            }
            return sum / wsum
        }
    }
}
