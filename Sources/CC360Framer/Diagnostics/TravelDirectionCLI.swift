import Foundation

/// `CC360Framer --travel-direction file.360`: prints the direction-of-travel windows and summary (diagnostic).
enum TravelDirectionCLI {
    static func run(url: URL) -> Int32 {
        let started = Date()
        guard let t = Telemetry.load(url: url) else { print("no telemetry"); return 1 }
        let loaded = Date().timeIntervalSince(started)
        let duration = max(t.accel.last?.t ?? 0, t.gpsSeries.last?.t ?? 0)
        let usable = t.gpsSeries.filter(\.isUsable).count
        print(String(format: "telemetry load %.2f s: accel %d, gps %d (%d usable), frames %d, duration %.1f s", loaded, t.accel.count, t.gpsSeries.count, usable, t.count, duration))
        let a = Date()
        guard let e = TravelDirection.analyse(telemetry: t, duration: duration) else { print("no estimate (not enough GPS or movement)"); return 2 }
        print(String(format: "analysis %.2f s; GPS lag %+.1f s; global fit %+.1f deg coherence %.2f", Date().timeIntervalSince(a), e.lag, e.globalYaw * 180 / .pi, e.globalCoherence))
        for w in e.windows {
            print(String(format: "  t=%6.1f  theta %+6.1f deg  coherence %.2f  samples %3d  %@", w.time, w.yaw * 180 / .pi, w.coherence, w.samples, w.accepted ? "accepted" : "rejected"))
        }
        print(e.summary)
        if e.isUsable {
            let samples = stride(from: 0.0, through: duration, by: max(duration / 8, 1)).map { String(format: "%.0fs:%+.0f", $0, Double(e.yaw(at: $0) ?? 0) * 180 / .pi) }
            print("smoothed yaw: " + samples.joined(separator: "  "))
        }
        return e.isUsable ? 0 : 2
    }
}
