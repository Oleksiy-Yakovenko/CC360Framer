import Foundation
import simd

/// Pure logic for the preview's "Display detected subjects" overlay.
enum Detections {
    /// Detections exist only for every 6th decoded frame (about 5 Hz at 30 fps, one step is ~0.2 s). The overlay shows the
    /// observation nearest in time and nothing when none is within `maxGap`, which is just under one analysis step:
    /// beyond that the boxes would be stale (before the first or after the last analysed frame, or inside an unanalysed range).
    static let maxGap = 0.2

    /// The observation nearest to `t` (binary search; `observations` must be sorted by time), or nil if none is within `maxGap`.
    static func observation(in observations: [Observation], at t: Double) -> Observation? {
        guard !observations.isEmpty else { return nil }
        var lo = 0, hi = observations.count   // first index with time >= t
        while lo < hi {
            let mid = (lo + hi) / 2
            if observations[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        var best: Observation?
        for i in [lo - 1, lo] where i >= 0 && i < observations.count {
            if best == nil || abs(observations[i].t - t) < abs(best!.t - t) { best = observations[i] }
        }
        guard let best, abs(best.t - t) <= maxGap else { return nil }
        return best
    }

    /// The preview camera, mirroring the Metal shader: a screen point (ndc.x * aspect * tanHalfFov, ndc.y * tanHalfFov, 1) is
    /// pitched, yawed, then mapped to the body frame with the stabiliser basis.
    struct Camera {
        var yaw: Float
        var pitch: Float
        var tanHalfFov: Float
        var aspect: Float
        var basis: Stabilizer.Basis = .identity
    }

    /// tan(fov / 2) the preview is drawn with: the export-frame guide scales it (see `ExportFrame.previewFovScale`).
    static func previewTanHalfFov(fovDegrees: Float, previewAspect: Double, exportAspect: Double?) -> Float {
        var scale = 1.0
        if let ea = exportAspect, previewAspect > 0 { scale = ExportFrame.previewFovScale(previewAspect: previewAspect, exportAspect: ea) }
        return tan(fovDegrees * .pi / 360) * Float(scale)
    }

    /// Body-frame direction (yaw, pitch) -> normalised screen coordinates (-1...1 across the view, y up), or nil behind the camera.
    static func project(yaw: Float, pitch: Float, camera c: Camera) -> SIMD2<Float>? {
        let d = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        var v = SIMD3<Float>(simd_dot(d, c.basis.right), simd_dot(d, c.basis.up), simd_dot(d, c.basis.forward))
        // Undo the shader's yaw, then its pitch.
        let cy = cos(c.yaw), sy = sin(c.yaw)
        v = SIMD3(v.x * cy - v.z * sy, v.y, v.x * sy + v.z * cy)
        let cp = cos(c.pitch), sp = sin(c.pitch)
        v = SIMD3(v.x, v.y * cp - v.z * sp, v.y * sp + v.z * cp)
        guard v.z > 1e-4, c.tanHalfFov > 0, c.aspect > 0 else { return nil }
        return SIMD2(v.x / v.z / (c.aspect * c.tanHalfFov), v.y / v.z / c.tanHalfFov)
    }

    struct Shape: Equatable {
        enum Kind { case person, salient }
        var kind: Kind
        /// 4 corners of the box, or a single point for detections stored without boxes.
        var points: [SIMD2<Float>]
        var isPoint: Bool { points.count == 1 }
    }

    /// Screen shapes of every detection in `observation`. A box with any corner behind the camera is skipped.
    static func shapes(for observation: Observation, camera: Camera) -> [Shape] {
        func shape(_ cand: Candidate, _ kind: Shape.Kind) -> Shape? {
            if let k = cand.corners, k.count == 8 {
                var pts: [SIMD2<Float>] = []
                for i in 0..<4 {
                    guard let p = project(yaw: k[2 * i], pitch: k[2 * i + 1], camera: camera) else { return nil }
                    pts.append(p)
                }
                return Shape(kind: kind, points: pts)
            }
            guard let p = project(yaw: cand.yaw, pitch: cand.pitch, camera: camera) else { return nil }
            return Shape(kind: kind, points: [p])
        }
        return observation.people.compactMap { shape($0, .person) } + observation.salient.compactMap { shape($0, .salient) }
    }
}
