import Foundation
import QuartzCore

/// Playback pacing diagnostics (CC360_PACING=<seconds> with CC360_DEBUG): records when each frame
/// was really presented on screen and which video frame it showed, then prints judder statistics.
enum Pacing {
    static let seconds = Double(ProcessInfo.processInfo.environment["CC360_PACING"] ?? "")
    static var enabled: Bool { seconds != nil }
    private static let lock = NSLock()
    // Mutable diagnostics state: every access is guarded by `lock`.
    nonisolated(unsafe) private static var draws: [Double] = []
    nonisolated(unsafe) private static var shown: [(presented: Double, pts: Double)] = []
    nonisolated(unsafe) private static var lastDraw = 0.0
    nonisolated(unsafe) private static var newFrameTimes: [Double] = []
    nonisolated(unsafe) private static var drawableWaits: [Double] = []
    nonisolated(unsafe) private static var drawBodies: [Double] = []

    nonisolated(unsafe) private static var gpuTimes: [Double] = []
    static func gpu(_ t: Double) { lock.lock(); gpuTimes.append(t); lock.unlock() }

    static func timing(drawableWait: Double, body: Double) {
        lock.lock(); drawableWaits.append(drawableWait); drawBodies.append(body); lock.unlock()
    }

    static func drew() {
        let now = CACurrentMediaTime()
        lock.lock(); if lastDraw > 0 { draws.append(now - lastDraw) }; lastDraw = now; lock.unlock()
    }

    static func presented(at t: Double, pts: Double) {
        lock.lock(); if t > 0 { shown.append((t, pts)) }; lock.unlock()
    }

    static func newFrame() {
        lock.lock(); newFrameTimes.append(CACurrentMediaTime()); lock.unlock()
    }

    static func report() {
        lock.lock(); defer { lock.unlock() }
        func stats(_ v: [Double], _ unit: Double = 1000) -> String {
            guard !v.isEmpty else { return "n/a" }
            let s = v.sorted(); let mean = s.reduce(0, +) / Double(s.count)
            return String(format: "mean %.1f  p95 %.1f  p99 %.1f  max %.1f ms", mean * unit, s[Int(Double(s.count) * 0.95)] * unit, s[Int(Double(s.count) * 0.99)] * unit, s.last! * unit)
        }
        print("--- pacing report ---")
        print("draw calls: \(draws.count)  interval: \(stats(draws))  (>25 ms: \(draws.filter { $0 > 0.025 }.count))")
        let pi = zip(shown.dropFirst(), shown).map { $0.presented - $1.presented }
        print("presented refreshes: \(shown.count)  interval: \(stats(pi))  (>25 ms: \(pi.filter { $0 > 0.025 }.count))")
        // How many refreshes each video frame was held for, and how many video frames were skipped.
        var holds: [Int: Int] = [:], skipped = 0, run = 0
        var prev = shown.first?.pts ?? 0
        for s in shown.dropFirst() {
            if abs(s.pts - prev) < 0.001 { run += 1 } else {
                holds[run + 1, default: 0] += 1
                let step = (s.pts - prev) * 29.97
                if step > 1.5 { skipped += Int((step - 1).rounded()) }
                if step < 0 { skipped += 1 }
                prev = s.pts; run = 0
            }
        }
        print("refreshes per video frame (1 = quick, 2 = ideal for 30 on 60 Hz, 3+ = hold): \(holds.sorted { $0.key < $1.key }.map { "\($0.key)x: \($0.value)" }.joined(separator: "  "))")
        print("video frames skipped: \(skipped)  of \(holds.values.reduce(0, +)) shown")
        let nf = zip(newFrameTimes.dropFirst(), newFrameTimes).map { $0 - $1 }
        print("compositor GPU time per frame (stack copy): \(stats(gpuTimes))")
        print("waiting for a drawable: \(stats(drawableWaits))")
        print("CPU time in draw (excl. drawable wait): \(stats(drawBodies))")
        print("new-frame pickup interval: \(stats(nf))")
        fflush(stdout)
    }
}
