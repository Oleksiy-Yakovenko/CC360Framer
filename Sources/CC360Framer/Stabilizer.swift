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

    /// Heading smoothing (seconds, gaussian sigma) for `.smooth`.
    static let smoothingSeconds: Float = 0.7

    private var bases: [Basis]
    private let rate: Double

    init(telemetry: Telemetry, duration: Double, mode: StabilizeMode) {
        let n = telemetry.count
        rate = Double(n) / max(duration, 0.001)
        guard mode != .off else { bases = [.identity]; return }
        let map = Self.sensorToRender

        // Body-frame "up" per frame, lightly smoothed (3-tap) to take the edge off sensor noise.
        let rawUp = telemetry.gravity.prefix(n).map { simd_normalize(-($0 * map)) }
        let up: [SIMD3<Float>] = (0..<n).map { i in
            simd_normalize(rawUp[max(i - 1, 0)] + 2 * rawUp[i] + rawUp[min(i + 1, n - 1)])
        }
        // Orientation quaternions in render axes. Axes are pseudovectors: mapping them through a
        // reflection S gives det(S) * S * axis.
        let det = map.x * map.y * map.z
        let q: [simd_quatf] = telemetry.orientation.prefix(n).map {
            simd_normalize(simd_quatf(ix: det * $0.y * map.x, iy: det * $0.z * map.y, iz: det * $0.w * map.z, r: $0.x))
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

        bases = (0..<n).map { i in
            let u = up[i]
            var f = headings[i] - simd_dot(headings[i], u) * u
            if simd_length(f) < 1e-4 { f = [0, 0, 1] - u.z * u }
            f = simd_normalize(f)
            return Basis(right: simd_cross(u, f), up: u, forward: f)
        }
    }

    func basis(at time: Double) -> Basis {
        if bases.count == 1 { return bases[0] }
        return bases[min(max(Int((time * rate).rounded()), 0), bases.count - 1)]
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
