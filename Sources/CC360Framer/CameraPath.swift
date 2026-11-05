import Foundation

/// One subject observation from the analysis pass.
struct Sample: Codable {
    var t: Double
    var yaw: Float
    var pitch: Float
    var weight: Float
}

struct Keyframe: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Double
    var yaw: Float        // radians, wrapped to [-pi, pi]
    var pitch: Float      // radians
    var fov: Float        // vertical degrees
}

@inline(__always) func wrapAngle(_ a: Float) -> Float { atan2(sin(a), cos(a)) }

/// Smooth camera path through keyframes (cubic Hermite with finite-difference tangents).
/// Yaw is unwrapped across keyframes so the camera takes the short way round.
struct CameraPath {
    private(set) var keys: [Keyframe]
    private var yaw: [Float] = []

    init(keys: [Keyframe]) {
        self.keys = keys.sorted { $0.time < $1.time }
        var prev: Float = 0
        for (i, k) in self.keys.enumerated() {
            let y = i == 0 ? k.yaw : prev + wrapAngle(k.yaw - prev)
            yaw.append(y)
            prev = y
        }
    }

    var isEmpty: Bool { keys.isEmpty }

    func sample(at t: Double) -> (yaw: Float, pitch: Float, fov: Float)? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if keys.count == 1 || t <= first.time { return (wrapAngle(yaw[0]), first.pitch, first.fov) }
        if t >= last.time { return (wrapAngle(yaw[keys.count - 1]), last.pitch, last.fov) }
        var lo = 0, hi = keys.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if keys[mid].time <= t { lo = mid } else { hi = mid } }
        let a = keys[lo], b = keys[hi]
        let h = Float(b.time - a.time)
        let u = Float(t - a.time) / h
        func hermite(_ ch: (Int) -> Float) -> Float {
            func tangent(_ i: Int) -> Float {
                if i == 0 || i == keys.count - 1 { return 0 }
                return (ch(i + 1) - ch(i - 1)) / Float(keys[i + 1].time - keys[i - 1].time)
            }
            let p0 = ch(lo), p1 = ch(hi), m0 = tangent(lo) * h, m1 = tangent(hi) * h
            let u2 = u * u, u3 = u2 * u
            return (2 * u3 - 3 * u2 + 1) * p0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * p1 + (u3 - u2) * m1
        }
        let y = hermite { yaw[$0] }
        let p = hermite { keys[$0].pitch }
        let f = hermite { keys[$0].fov }
        return (wrapAngle(y), max(-1.5, min(1.5, p)), max(20, min(140, f)))
    }
}

/// Turns raw per-frame subject observations into a smooth, sparse set of editable keyframes.
enum PathBuilder {
    static func build(samples: [Sample], duration: Double, fov: Float = 90) -> [Keyframe] {
        let dt = 0.2
        let n = max(Int(duration / dt) + 1, 2)
        // Resample to a uniform grid; hold the last observation through gaps.
        var yaw = [Float?](repeating: nil, count: n), pitch = [Float?](repeating: nil, count: n)
        for s in samples {
            let i = min(max(Int((s.t / dt).rounded()), 0), n - 1)
            yaw[i] = s.yaw; pitch[i] = s.pitch
        }
        guard yaw.contains(where: { $0 != nil }) else { return [] }
        var ry = [Float](repeating: 0, count: n), rp = [Float](repeating: 0, count: n)
        var lastY: Float?, lastP: Float?
        for i in 0..<n {
            if let y = yaw[i] { lastY = y; lastP = pitch[i] }
            if let y = lastY { ry[i] = y; rp[i] = lastP! } else { ry[i] = .nan }
        }
        if let firstIdx = ry.firstIndex(where: { !$0.isNaN }) {
            for i in 0..<firstIdx { ry[i] = ry[firstIdx]; rp[i] = rp[firstIdx] }
        }
        // Unwrap yaw so smoothing does not average across the ±pi seam.
        for i in 1..<n { ry[i] = ry[i - 1] + wrapAngle(ry[i] - ry[i - 1]) }

        ry = smooth(median(ry, radius: 2), sigma: 6)
        rp = smooth(median(rp, radius: 2), sigma: 6)
        ry = limitSpeed(ry, maxStep: 100 * .pi / 180 * Float(dt))
        rp = limitSpeed(rp, maxStep: 60 * .pi / 180 * Float(dt))

        // Keep only the points needed to reproduce the curve within ~1.5°.
        var keep = Set([0, n - 1])
        decimate(ry, rp, lo: 0, hi: n - 1, tol: 1.5 * .pi / 180, keep: &keep)
        return keep.sorted().map {
            Keyframe(time: Double($0) * dt, yaw: wrapAngle(ry[$0]), pitch: rp[$0], fov: fov)
        }
    }

    private static func median(_ a: [Float], radius: Int) -> [Float] {
        (0..<a.count).map { i in
            let w = a[max(0, i - radius)...min(a.count - 1, i + radius)].sorted()
            return w[w.count / 2]
        }
    }

    private static func smooth(_ a: [Float], sigma: Float) -> [Float] {
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

    private static func limitSpeed(_ a: [Float], maxStep: Float) -> [Float] {
        var o = a
        for i in 1..<o.count { o[i] = o[i - 1] + max(-maxStep, min(maxStep, o[i] - o[i - 1])) }
        for i in stride(from: o.count - 2, through: 0, by: -1) { o[i] = o[i + 1] + max(-maxStep, min(maxStep, o[i] - o[i + 1])) }
        return o
    }

    private static func decimate(_ y: [Float], _ p: [Float], lo: Int, hi: Int, tol: Float, keep: inout Set<Int>) {
        guard hi - lo > 1 else { return }
        var worst = 0, worstErr: Float = 0
        for i in (lo + 1)..<hi {
            let u = Float(i - lo) / Float(hi - lo)
            let e = max(abs(y[i] - (y[lo] + u * (y[hi] - y[lo]))), abs(p[i] - (p[lo] + u * (p[hi] - p[lo]))))
            if e > worstErr { worstErr = e; worst = i }
        }
        guard worstErr > tol else { return }
        keep.insert(worst)
        decimate(y, p, lo: lo, hi: worst, tol: tol, keep: &keep)
        decimate(y, p, lo: worst, hi: hi, tol: tol, keep: &keep)
    }
}
