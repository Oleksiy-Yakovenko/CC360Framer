import Foundation

/// Links detections across consecutive observations into tracks, so the path builder can ignore
/// things that are only seen briefly (Vision flicker, a passing car, a false positive).
/// Detections carry no identity, so association is purely geometric and per kind
/// (people with people, salient with salient).
enum DetectionTracks {
    /// Fastest apparent motion of one subject in the body frame, deg/s. A rider or an object passed on
    /// the side sweeps a good deal faster than the 0.2 s step suggests, but 60 deg/s (12 deg per step)
    /// still keeps two different objects a few metres apart from merging.
    static let maxAngularSpeed: Float = 60 * .pi / 180
    /// Constant slack added to the speed gate for box jitter between frames.
    static let jitterSlack: Float = 3 * .pi / 180
    /// Longest time between two detections of one track: two missed analysis steps (0.2 s each) plus rounding.
    static let maxGap = 0.65

    private struct Track { var first: Double; var last: Double; var yaw: Float; var pitch: Float; var id: Int }

    /// Duration (last minus first detection) of the track each candidate belongs to, indexed like the input.
    private static func trackIDs(_ obs: [Observation], _ pick: (Observation) -> [Candidate]) -> (ids: [[Int]], span: [Double]) {
        var active: [Track] = []
        var span: [Double] = []
        var ids: [[Int]] = []
        for o in obs {
            let cands = pick(o)
            active.removeAll { o.t - $0.last > maxGap }
            var pairs: [(d: Float, c: Int, t: Int)] = []
            for (ci, c) in cands.enumerated() {
                for (ti, tr) in active.enumerated() {
                    let gate = maxAngularSpeed * Float(o.t - tr.last) + jitterSlack
                    let dy = wrapAngle(c.yaw - tr.yaw), dp = c.pitch - tr.pitch
                    let d = (dy * dy + dp * dp).squareRoot()
                    if d <= gate { pairs.append((d, ci, ti)) }
                }
            }
            pairs.sort { $0.d < $1.d }
            var assigned = [Int?](repeating: nil, count: cands.count)
            var used = Set<Int>()
            for p in pairs where assigned[p.c] == nil && !used.contains(p.t) {
                assigned[p.c] = p.t; used.insert(p.t)
            }
            var row: [Int] = []
            for (ci, c) in cands.enumerated() {
                if let ti = assigned[ci] {
                    active[ti].last = o.t; active[ti].yaw = c.yaw; active[ti].pitch = c.pitch
                    span[active[ti].id] = o.t - active[ti].first
                    row.append(active[ti].id)
                } else {
                    let id = span.count
                    span.append(0)
                    active.append(Track(first: o.t, last: o.t, yaw: c.yaw, pitch: c.pitch, id: id))
                    row.append(id)
                }
            }
            ids.append(row)
        }
        return (ids, span)
    }

    /// Removes every candidate that belongs to a track detected for less than `minDuration` seconds.
    /// Keeps `t`, order and all candidate fields. Observations are sorted by time first.
    /// A track cut off by the clip's start or end is judged strictly by its detected duration;
    /// only when the whole clip (`clipDuration`, default: the span of the observations) is shorter
    /// than `minDuration` nothing is filtered, since no track could ever qualify.
    static func filter(_ input: [Observation], minDuration: Double = 2.0, clipDuration: Double? = nil) -> [Observation] {
        guard let f = input.first, let l = input.last else { return input }
        let obs = zip(input, input.dropFirst()).allSatisfy({ $0.t <= $1.t }) ? input : input.sorted { $0.t < $1.t }
        let clip = clipDuration ?? ((obs.last?.t ?? l.t) - (obs.first?.t ?? f.t))
        if clip < minDuration { return obs }

        let people = trackIDs(obs) { $0.people }
        let salient = trackIDs(obs) { $0.salient }
        return obs.enumerated().map { i, o in
            var r = o
            r.people = zip(o.people, people.ids[i]).filter { people.span[$1] >= minDuration }.map(\.0)
            r.salient = zip(o.salient, salient.ids[i]).filter { salient.span[$1] >= minDuration }.map(\.0)
            return r
        }
    }
}
