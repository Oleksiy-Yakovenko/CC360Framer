import Foundation

/// Ways of turning raw observations into a camera path.
enum PathStyle: String, CaseIterable, Identifiable {
    case follow = "Follow subject"
    case scenery = "Scenery + rider"
    var id: String { rawValue }

    func keyframes(from obs: [Observation], duration: Double, fov: Float) -> [Keyframe] {
        switch self {
        case .follow:
            return PathBuilder.build(samples: Self.followSamples(obs), duration: duration, fov: fov)
        case .scenery:
            return PathBuilder.build(samples: SceneryPlanner.plan(obs, duration: duration),
                                     duration: duration, fov: fov, params: .scenery)
        }
    }

    /// Keep one subject in view: the largest person, preferring the one closest to the previous target.
    static func followSamples(_ obs: [Observation]) -> [Sample] {
        var previous: (yaw: Float, pitch: Float)?
        var out: [Sample] = []
        for o in obs {
            guard let best = o.people.max(by: { continuityWeight($0, previous) < continuityWeight($1, previous) }) else { continue }
            previous = (best.yaw, best.pitch)
            out.append(Sample(t: o.t, yaw: best.yaw, pitch: best.pitch, weight: best.score, fov: nil))
        }
        return out
    }
}

/// Score boosted for candidates near the previous target, so the camera sticks to what it was showing.
func continuityWeight(_ c: Candidate, _ prev: (yaw: Float, pitch: Float)?) -> Float {
    guard let prev else { return c.score }
    let dist = abs(wrapAngle(c.yaw - prev.yaw)) + abs(c.pitch - prev.pitch)
    let sigma: Float = 40 * .pi / 180
    return c.score * (1 + 2 * exp(-dist * dist / (2 * sigma * sigma)))
}

/// Looks forward along the direction of travel, glances at interesting objects on the sides,
/// and now and then swings round to show the rider. Camera "forward" is yaw 0 (the camera is
/// fixed to the bike), and the rider is found as the typical person direction.
enum SceneryPlanner {
    private enum Kind { case forward, side, rider }
    /// Shot rotation with nominal lengths in seconds: mostly road, a glance every other shot.
    private static let cycle: [(Kind, Double)] = [(.forward, 6), (.side, 3.5), (.forward, 6), (.side, 3.5), (.forward, 5)]
    /// The rider only appears when a side slot has nothing interesting, at most this often and this many times.
    private static let riderGap = 60.0
    private static let riderMax = 2
    private static let riderShotLength = 3.0
    /// Salient things this close to the rider are the rider's own bike and gear, not scenery.
    private static let riderExclusion: Float = 50 * .pi / 180
    private static let dt = 0.2
    private static let forwardFov: Float = 70
    private static let closeFov: Float = 55
    private static let sideRange: ClosedRange<Float> = (35 * .pi / 180)...(145 * .pi / 180)

    static func plan(_ obs: [Observation], duration: Double) -> [Sample] {
        var byIndex: [Int: Observation] = [:]
        for o in obs { byIndex[Int((o.t / dt).rounded())] = o }
        let rider = riderReference(obs)
        let total = Int(duration / dt) + 1

        var samples: [Sample] = []
        var i = 0, shot = 0, lastSide: Float = 0
        var lastRiderT = 0.0, riderCount = 0
        while i < total {
            let (planned, nominal) = cycle[shot % cycle.count]
            // Vary lengths a little so the rhythm does not feel mechanical.
            let length = max(Int((nominal * (1 + 0.15 * sin(Double(shot) * 1.7)) / dt).rounded()), 1)
            var end = min(i + length, total)
            var made: [Sample] = []
            switch planned {
            case .side:
                if let r = sideShot(byIndex, i..<end, lastSide: lastSide, rider: rider) {
                    made = r.samples; lastSide = r.side
                } else if let rider, riderCount < riderMax, Double(i) * dt - lastRiderT >= riderGap {
                    let rEnd = min(i + Int(riderShotLength / dt), total)
                    made = riderShot(byIndex, i..<rEnd, ref: rider)
                    end = rEnd; lastRiderT = Double(i) * dt; riderCount += 1
                }
            case .rider:
                break
            case .forward:
                break
            }
            samples += made.isEmpty ? forwardShot(i..<end) : made
            i = end
            shot += 1
        }
        return samples
    }

    private static func forwardShot(_ r: Range<Int>) -> [Sample] {
        r.map { Sample(t: Double($0) * dt, yaw: 0, pitch: 0, weight: 1, fov: forwardFov) }
    }

    private static func riderShot(_ obs: [Int: Observation], _ r: Range<Int>, ref: (yaw: Float, pitch: Float)) -> [Sample] {
        r.map { i in
            // Track the rider's actual detection when there is one close to the usual spot.
            let near = obs[i]?.people.filter { abs(wrapAngle($0.yaw - ref.yaw)) < 45 * .pi / 180 }
                .max { $0.score < $1.score }
            return Sample(t: Double(i) * dt, yaw: near?.yaw ?? ref.yaw, pitch: near?.pitch ?? ref.pitch, weight: 1, fov: closeFov)
        }
    }

    /// Picks the side with the more interesting objects (alternating when similar) and follows one object.
    private static func sideShot(_ obs: [Int: Observation], _ r: Range<Int>, lastSide: Float, rider: (yaw: Float, pitch: Float)?) -> (samples: [Sample], side: Float)? {
        func candidates(_ i: Int, _ side: Float) -> [Candidate] {
            obs[i]?.salient.filter { c in
                c.yaw.sign == (side > 0 ? .plus : .minus) && sideRange.contains(abs(c.yaw))
                    && !(rider.map { abs(wrapAngle(c.yaw - $0.yaw)) < riderExclusion } ?? false)
            } ?? []
        }
        func strength(_ side: Float) -> Float {
            r.reduce(0) { $0 + (candidates($1, side).map(\.score).max() ?? 0) } * (side == lastSide ? 0.6 : 1)
        }
        let side: Float = strength(1) >= strength(-1) ? 1 : -1
        guard strength(side) / Float(r.count) > 0.08 else { return nil }

        // Follow one object through the shot, sticking with it as the bike moves past.
        var previous: (yaw: Float, pitch: Float)?
        var targets: [(Float, Float)?] = []
        for i in r {
            if let best = candidates(i, side).max(by: { continuityWeight($0, previous) < continuityWeight($1, previous) }) {
                previous = (best.yaw, best.pitch)
                targets.append((best.yaw, best.pitch))
            } else {
                targets.append(nil)
            }
        }
        guard let first = targets.first(where: { $0 != nil }) ?? nil else { return nil }
        var last = first
        let samples: [Sample] = zip(r, targets).map { i, t in
            if let t { last = t }
            return Sample(t: Double(i) * dt, yaw: last.0, pitch: last.1, weight: 1, fov: closeFov)
        }
        return (samples, side)
    }

    /// The typical person direction (circular mean, outliers dropped), or nil if nobody was seen.
    private static func riderReference(_ obs: [Observation]) -> (yaw: Float, pitch: Float)? {
        let tops = obs.compactMap { $0.people.max { $0.score < $1.score } }
        guard tops.count >= 3 else { return nil }
        func mean(_ c: [Candidate]) -> (yaw: Float, pitch: Float) {
            (atan2(c.reduce(0) { $0 + sin($1.yaw) }, c.reduce(0) { $0 + cos($1.yaw) }),
             c.reduce(0) { $0 + $1.pitch } / Float(c.count))
        }
        let first = mean(tops)
        let close = tops.filter { abs(wrapAngle($0.yaw - first.yaw)) < 40 * .pi / 180 }
        return close.count >= 3 ? mean(close) : first
    }
}
