import Foundation

/// Display-time post-processing of stored detections for the preview overlay: merges the duplicates that come from the eight
/// overlapping analysis views and finds groups of people. Pure; nothing here touches the stored data or the path building.
enum DetectionGroups {
    /// Two views are 45 degrees apart with a 90 degree fov, so a person near a view edge shows up in two views, usually with
    /// slightly different (edge-clipped) boxes. Two different people side by side rarely overlap by more than a third of their
    /// union, while real duplicates overlap far more, so 0.4 separates them; the centre-inside rule below catches the clipped
    /// duplicates whose IoU is lower.
    static let duplicateIoU: Float = 0.4

    /// People are linked into one cluster when the horizontal gap between their boxes is below this many widths of the
    /// narrower box (kids standing shoulder to shoulder have gaps of well under one body width) ...
    static let linkGapFactor: Float = 0.75
    /// ... and the vertical gap is below this many heights of the shorter box (so a head-to-toe row of people links, people
    /// far above or below each other do not).
    static let linkVerticalFactor: Float = 0.5
    /// Fewest people that make a group.
    static let minGroupSize = 3

    /// A box in angular space: centre (yaw, pitch) and half extents, all radians. Yaw differences are always wrapped.
    struct Box: Equatable {
        var yaw: Float, pitch: Float, halfW: Float, halfH: Float

        /// From the 8-float corner list; yaw is measured relative to the first corner so +-pi is safe.
        init?(corners k: [Float]?) {
            guard let k, k.count == 8 else { return nil }
            let ref = k[0]
            var dx: [Float] = [], ps: [Float] = []
            for i in 0..<4 { dx.append(DetectionGroups.wrap(k[2 * i] - ref)); ps.append(k[2 * i + 1]) }
            let x0 = dx.min()!, x1 = dx.max()!, p0 = ps.min()!, p1 = ps.max()!
            self.init(yaw: DetectionGroups.wrap(ref + (x0 + x1) / 2), pitch: (p0 + p1) / 2, halfW: (x1 - x0) / 2, halfH: (p1 - p0) / 2)
        }

        init(yaw: Float, pitch: Float, halfW: Float, halfH: Float) {
            self.yaw = yaw; self.pitch = pitch; self.halfW = halfW; self.halfH = halfH
        }

        /// Signed yaw offset and overlap length of the two boxes' yaw ranges.
        private func yawRelation(_ o: Box) -> (dx: Float, overlap: Float) {
            let dx = DetectionGroups.wrap(o.yaw - yaw)
            return (dx, min(halfW, dx + o.halfW) - max(-halfW, dx - o.halfW))
        }

        func iou(_ o: Box) -> Float {
            let ox = yawRelation(o).overlap
            let oy = min(pitch + halfH, o.pitch + o.halfH) - max(pitch - halfH, o.pitch - o.halfH)
            guard ox > 0, oy > 0 else { return 0 }
            let inter = ox * oy
            let union = 4 * halfW * halfH + 4 * o.halfW * o.halfH - inter
            return union > 0 ? inter / union : 0
        }

        func contains(centreOf o: Box) -> Bool {
            abs(DetectionGroups.wrap(o.yaw - yaw)) <= halfW && abs(o.pitch - pitch) <= halfH
        }

        /// Horizontal and vertical gaps (0 when the ranges overlap).
        func gaps(to o: Box) -> (h: Float, v: Float) {
            let dx = DetectionGroups.wrap(o.yaw - yaw)
            return (max(0, abs(dx) - halfW - o.halfW), max(0, abs(o.pitch - pitch) - halfH - o.halfH))
        }

        /// Corner list in the stored order: bottom-left, bottom-right, top-right, top-left.
        var corners: [Float] {
            let l = yaw - halfW, r = yaw + halfW, b = pitch - halfH, t = pitch + halfH
            return [l, b, r, b, r, t, l, t]
        }
    }

    static func wrap(_ a: Float) -> Float {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x > .pi { x -= 2 * .pi } else if x < -.pi { x += 2 * .pi }
        return x
    }

    static func isDuplicate(_ a: Box, _ b: Box) -> Bool {
        a.iou(b) > duplicateIoU || a.contains(centreOf: b) || b.contains(centreOf: a)
    }

    /// Drops duplicates among candidates with boxes, keeping the higher-score one of each pair (its own box, not a union:
    /// the views clip boxes differently and a union would inflate them). Candidates without corners are always kept.
    /// Input order is preserved.
    static func merged(_ cands: [Candidate]) -> [Candidate] {
        let order = cands.indices.sorted { cands[$0].score != cands[$1].score ? cands[$0].score > cands[$1].score : $0 < $1 }
        var kept: [Box] = []
        var keep = Set<Int>()
        for i in order {
            guard let box = Box(corners: cands[i].corners) else { keep.insert(i); continue }
            if kept.contains(where: { isDuplicate($0, box) }) { continue }
            kept.append(box)
            keep.insert(i)
        }
        return cands.indices.filter { keep.contains($0) }.map { cands[$0] }
    }

    /// Union boxes of every cluster of at least `minGroupSize` people (single linkage). Candidates without corners are ignored.
    static func groups(_ people: [Candidate]) -> [Box] {
        let boxes = people.compactMap { Box(corners: $0.corners) }
        let n = boxes.count
        guard n >= minGroupSize else { return [] }
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in 0..<n {
            for j in (i + 1)..<n {
                let g = boxes[i].gaps(to: boxes[j])
                let narrow = 2 * min(boxes[i].halfW, boxes[j].halfW), short = 2 * min(boxes[i].halfH, boxes[j].halfH)
                if g.h < linkGapFactor * narrow && g.v <= linkVerticalFactor * short { parent[find(i)] = find(j) }
            }
        }
        var clusters: [Int: [Int]] = [:]
        for i in 0..<n { clusters[find(i), default: []].append(i) }
        return clusters.values.filter { $0.count >= minGroupSize }.sorted { $0[0] < $1[0] }.map { members in
            let ref = boxes[members[0]].yaw
            var x0 = Float.infinity, x1 = -Float.infinity, p0 = Float.infinity, p1 = -Float.infinity
            for m in members {
                let b = boxes[m], dx = wrap(b.yaw - ref)
                x0 = min(x0, dx - b.halfW); x1 = max(x1, dx + b.halfW)
                p0 = min(p0, b.pitch - b.halfH); p1 = max(p1, b.pitch + b.halfH)
            }
            return Box(yaw: ref + (x0 + x1) / 2, pitch: (p0 + p1) / 2, halfW: (x1 - x0) / 2, halfH: (p1 - p0) / 2)
        }
    }
}
