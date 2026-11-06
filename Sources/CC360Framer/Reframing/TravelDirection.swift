import Foundation
import simd

/// Where the vehicle really goes, relative to the camera body: the camera is mounted at an arbitrary angle, so "forward"
/// (the direction of travel) is rarely body yaw 0. The accelerometer measures the vehicle's acceleration in body axes, GPS
/// gives the same acceleration in the direction of travel (speed change) and across it (speed x turn rate); the rotation
/// that maps one onto the other is the mount offset. Pure logic, no AVFoundation or Metal.
///
/// Model per GPS sample, with complex numbers (real = along the body's levelled front, imaginary = along its right):
/// `a_front + i a_right = e^{i theta} (L + i Lat)` where `L` = d(speed)/dt and `Lat` = speed x d(course)/dt (positive = turning
/// right). `theta` is the yaw of the direction of travel in body axes (positive = right of the camera front).
/// It is fitted over 20 s windows; windows without enough speed change or turning (low coherence) are rejected, and
/// in between (stationary, no GPS) the estimate holds the nearest accepted value.
enum TravelDirection {
    /// Accelerometer reading as specific force (what the sensor measures, so +up x 9.81 at rest) in render axes
    /// (x right, y up, z front of the camera body).
    struct Accel {
        var t: Double
        var force: SIMD3<Float>
    }

    struct Window: Equatable {
        /// Centre of the window (seconds).
        var time: Double
        /// Fitted yaw of travel in body axes, radians, positive = right.
        var yaw: Double
        /// |sum conj(m) a|^2 / (sum |m|^2 sum |a|^2): 1 = the GPS acceleration explains the accelerometer fully.
        var coherence: Double
        /// GPS samples (moving, locked) used.
        var samples: Int
        var accepted: Bool
    }

    struct Estimate {
        var windows: [Window]
        /// GPS-to-accelerometer delay found by the global fit (seconds).
        var lag: Double
        /// Yaw and coherence of one fit over the whole clip (cross-check).
        var globalYaw: Double
        var globalCoherence: Double

        var accepted: [Window] { windows.filter(\.accepted) }
        var isUsable: Bool { windows.contains(where: \.accepted) }

        /// Smoothing of the window values over time (seconds, gaussian sigma).
        static let smoothing = 30.0

        /// Direction of travel in body axes (radians, positive = right) at `time`: accepted windows blended with
        /// weights coherence x gaussian(distance); beyond the first/last accepted window the nearest value holds.
        func yaw(at time: Double) -> Float? {
            let acc = accepted
            guard !acc.isEmpty else { return nil }
            var sx = 0.0, sy = 0.0, sw = 0.0
            for w in acc {
                let d = (time - w.time) / Self.smoothing
                let weight = w.coherence * exp(-0.5 * d * d)
                sx += weight * cos(w.yaw); sy += weight * sin(w.yaw); sw += weight
            }
            if sw < 1e-9 {
                let nearest = acc.min { abs($0.time - time) < abs($1.time - time) }!
                return Float(nearest.yaw)
            }
            return Float(atan2(sy, sx))
        }

        /// Coherence-weighted circular mean of the accepted windows, degrees (positive = right).
        var meanDegrees: Double? {
            let acc = accepted
            guard !acc.isEmpty else { return nil }
            let x = acc.reduce(0.0) { $0 + $1.coherence * cos($1.yaw) }, y = acc.reduce(0.0) { $0 + $1.coherence * sin($1.yaw) }
            return atan2(y, x) * 180 / .pi
        }

        var summary: String {
            guard let deg = meanDegrees else { return "No direction of travel found (no accepted windows)." }
            let side = deg >= 0 ? "right" : "left"
            return String(format: "%.0f deg %@ of camera front (%d of %d windows accepted)", abs(deg), side, accepted.count, windows.count)
        }
    }

    /// Settings value of the per-file / default "Forward" choice.
    enum ForwardMode: String, CaseIterable, Codable {
        case travelDirection, cameraFront

        var title: String { self == .travelDirection ? "Direction of travel" : "Camera front" }
        static let defaultsKey = "forwardMode"
        static func loadDefault(_ d: UserDefaults = .standard) -> ForwardMode {
            d.string(forKey: defaultsKey).flatMap(ForwardMode.init(rawValue:)) ?? .travelDirection
        }
    }

    /// The direction of travel as a yaw in the stabilised (virtual) camera, for `SceneryPlanner`. Nil = camera front
    /// (no estimate, or `mode` says so). The estimate is in body axes: the horizontal direction at that yaw in the levelled
    /// body is converted with the stabiliser basis, so a tilted camera does not skew it.
    static func forwardYaw(mode: ForwardMode, estimate: Estimate?, stabilizer: Stabilizer?) -> ((Double) -> Float)? {
        guard mode == .travelDirection, let estimate, estimate.isUsable else { return nil }
        return { t in
            guard let body = estimate.yaw(at: t) else { return 0 }
            guard let stabilizer else { return body }
            let up = stabilizer.basis(at: t).up
            var f = SIMD3<Float>(0, 0, 1) - up.z * up
            f = simd_length(f) < 1e-3 ? SIMD3<Float>(1, 0, 0) - up.x * up : f
            f = simd_normalize(f)
            let d = f * cos(body) + simd_cross(up, f) * sin(body)
            return stabilizer.toVirtual(yaw: atan2(d.x, d.z), pitch: asin(max(-1, min(1, d.y))), at: t).yaw
        }
    }

    // MARK: Parameters

    static let minSpeed = 2.0
    static let windowLength = 20.0
    static let windowStep = 10.0
    static let acceptCoherence = 0.4
    static let accelSigma = 0.45
    static let lagRange = 1.0

    /// The estimate, or nil when there is no usable direction (no GPS, never moving, nothing coherent).
    static func estimate(accel: [Accel], up: [SIMD3<Float>], upRate: Double, gps: [Telemetry.GPSSample]) -> Estimate? {
        guard let e = analyse(accel: accel, up: up, upRate: upRate, gps: gps), e.isUsable else { return nil }
        return e
    }

    /// Same, from the clip's telemetry (ACCL channels and gravity mapped to render axes). `duration` gives the frame rate of `gravity`.
    static func estimate(telemetry t: Telemetry, duration: Double) -> Estimate? {
        guard let e = analyse(telemetry: t, duration: duration), e.isUsable else { return nil }
        return e
    }

    static func analyse(telemetry t: Telemetry, duration: Double) -> Estimate? {
        guard !t.accel.isEmpty, !t.gravity.isEmpty, !t.gpsSeries.isEmpty, duration > 0 else { return nil }
        let map = Stabilizer.sensorToRender
        // ACCL channels (0,1,2) read +9.8 x (gravity y, x, z) at rest, so the specific force in sensor axes is (-c1, -c0, -c2).
        let accel = t.accel.map { Accel(t: $0.t, force: SIMD3<Float>(-$0.channels.y, -$0.channels.x, -$0.channels.z) * map) }
        let up = t.gravity.map { simd_normalize(-($0 * map)) }
        return analyse(accel: accel, up: up, upRate: Double(up.count) / duration, gps: t.gpsSeries)
    }

    /// Full analysis including rejected windows (for the diagnostic tool); nil when the inputs are insufficient.
    static func analyse(accel: [Accel], up: [SIMD3<Float>], upRate: Double, gps: [Telemetry.GPSSample]) -> Estimate? {
        guard accel.count > 20, !up.isEmpty, upRate > 0, gps.count > 20 else { return nil }
        let usable = gps.map(\.isUsable)
        guard usable.filter({ $0 }).count > 20 else { return nil }

        // Horizontal acceleration along the levelled body front and right, smoothed.
        let accelRate = Double(accel.count - 1) / max(accel[accel.count - 1].t - accel[0].t, 1e-3)
        var af = [Double](repeating: 0, count: accel.count), ar = af
        for (i, a) in accel.enumerated() {
            let u = upAt(up, upRate, a.t)
            var f = SIMD3<Float>(0, 0, 1) - u.z * u
            f = simd_length(f) < 1e-3 ? SIMD3<Float>(1, 0, 0) - u.x * u : f
            f = simd_normalize(f)
            let r = simd_cross(u, f)
            let h = a.force - simd_dot(a.force, u) * u
            af[i] = Double(simd_dot(h, f)); ar[i] = Double(simd_dot(h, r))
        }
        af = smooth(af, sigma: accelSigma * accelRate); ar = smooth(ar, sigma: accelSigma * accelRate)
        let accelT = accel.map(\.t)

        // GPS: positions and speed, filled over unusable stretches (those samples are masked out later).
        let n = gps.count
        let tg = gps.map(\.t)
        let fs = Double(n - 1) / max(tg[n - 1] - tg[0], 1e-3)
        func filled(_ v: [Double]) -> [Double] {
            let idx = (0..<n).filter { usable[$0] }
            var out = v
            var j = 0
            for i in 0..<n {
                while j + 1 < idx.count && idx[j + 1] <= i { j += 1 }
                if usable[i] { continue }
                let lo = idx[j] <= i ? idx[j] : nil
                let hi = idx.first { $0 > i }
                switch (lo, hi) {
                case let (l?, h?): out[i] = v[l] + (v[h] - v[l]) * Double(i - l) / Double(h - l)
                case let (l?, nil): out[i] = v[l]
                case let (nil, h?): out[i] = v[h]
                default: break
                }
            }
            return out
        }
        let lat = filled(gps.map(\.latitude)), lon = filled(gps.map(\.longitude)), spd = filled(gps.map(\.speed2D))
        let first = (0..<n).first { usable[$0] }!
        let earth = 6_371_000.0, lat0 = lat[first] * .pi / 180
        let x = smooth(lon.map { ($0 - lon[first]) * .pi / 180 * cos(lat0) * earth }, sigma: 0.3 * fs)
        let y = smooth(lat.map { ($0 - lat[first]) * .pi / 180 * earth }, sigma: 0.3 * fs)
        let vx = gradient(x, tg), vy = gradient(y, tg)
        var course = (0..<n).map { atan2(vx[$0], vy[$0]) }   // 0 = north, clockwise (right turn) positive
        for i in 1..<n { course[i] = course[i - 1] + wrap(course[i] - course[i - 1]) }
        let speed = smooth(spd, sigma: 0.3 * fs)
        let along = smooth(gradient(speed, tg), sigma: 0.5 * fs)
        let turn = gradient(smooth(course, sigma: 0.7 * fs), tg)
        let across = (0..<n).map { speed[$0] * turn[$0] }

        func fit(_ mask: [Int], lag: Double) -> (yaw: Double, coherence: Double) {
            var cr = 0.0, ci = 0.0, em = 0.0, ea = 0.0
            for i in mask {
                let a = sample(accelT, af, tg[i] + lag), b = sample(accelT, ar, tg[i] + lag)
                // conj(m) * a with m = along + i across, a = a_front + i a_right
                cr += along[i] * a + across[i] * b
                ci += along[i] * b - across[i] * a
                em += along[i] * along[i] + across[i] * across[i]
                ea += a * a + b * b
            }
            return (atan2(ci, cr), (cr * cr + ci * ci) / max(em * ea, 1e-12))
        }
        let moving = (0..<n).filter { usable[$0] && speed[$0] > minSpeed }
        guard moving.count >= 20 else { return nil }

        // GPS-to-accelerometer delay: the lag with the best global coherence.
        var best = (lag: 0.0, yaw: 0.0, coherence: -1.0)
        for step in -Int(lagRange * 10)...Int(lagRange * 10) {
            let lag = Double(step) / 10
            let f = fit(moving, lag: lag)
            if f.coherence > best.coherence { best = (lag, f.yaw, f.coherence) }
        }

        var windows: [Window] = []
        let t0 = tg[0], t1 = tg[n - 1]
        var starts = Array(stride(from: t0, through: t1 - windowLength + 1e-9, by: windowStep))
        if starts.isEmpty { starts = [t0] }
        for s in starts {
            let e = s + windowLength
            let mask = moving.filter { tg[$0] >= s && tg[$0] < e }
            guard Double(mask.count) >= 0.4 * min(windowLength, t1 - t0) * fs else { continue }
            let f = fit(mask, lag: best.lag)
            windows.append(Window(time: (s + min(e, t1)) / 2, yaw: f.yaw, coherence: f.coherence, samples: mask.count,
                                  accepted: f.coherence >= acceptCoherence))
        }
        return Estimate(windows: windows, lag: best.lag, globalYaw: best.yaw, globalCoherence: best.coherence)
    }

    // MARK: Numeric helpers

    private static func wrap(_ a: Double) -> Double { a - 2 * .pi * (a / (2 * .pi)).rounded() }

    private static func upAt(_ up: [SIMD3<Float>], _ rate: Double, _ t: Double) -> SIMD3<Float> {
        let f = min(max(t * rate - 0.5, 0), Double(up.count - 1))
        let i = min(Int(f), max(up.count - 2, 0)), w = Float(f - Double(i))
        if up.count == 1 { return up[0] }
        return simd_normalize(up[i] * (1 - w) + up[i + 1] * w)
    }

    /// Linear interpolation of `v` (at increasing `times`) at `t`; edge values hold.
    private static func sample(_ times: [Double], _ v: [Double], _ t: Double) -> Double {
        if t <= times[0] { return v[0] }
        if t >= times[times.count - 1] { return v[v.count - 1] }
        var lo = 0, hi = times.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if times[m] <= t { lo = m } else { hi = m } }
        let w = (t - times[lo]) / max(times[hi] - times[lo], 1e-9)
        return v[lo] + (v[hi] - v[lo]) * w
    }

    /// Central differences with the real sample times.
    private static func gradient(_ v: [Double], _ t: [Double]) -> [Double] {
        let n = v.count
        return (0..<n).map { i in
            let a = max(i - 1, 0), b = min(i + 1, n - 1)
            return (v[b] - v[a]) / max(t[b] - t[a], 1e-6)
        }
    }

    /// Zero-phase gaussian smoothing with edge renormalisation (sigma in samples).
    static func smooth(_ a: [Double], sigma: Double) -> [Double] {
        guard sigma > 0.3, !a.isEmpty else { return a }
        let r = Int(sigma * 2.5)
        let kernel = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        return (0..<a.count).map { i in
            var sum = 0.0, wsum = 0.0
            for k in max(-r, -i)...min(r, a.count - 1 - i) {
                let w = kernel[k + r]; sum += w * a[i + k]; wsum += w
            }
            return sum / wsum
        }
    }
}
