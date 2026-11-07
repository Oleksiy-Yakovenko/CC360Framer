import Foundation

/// Record mode: the keyframes captured during one camera gesture (drag, scroll zoom, pinch). Pure value logic;
/// `PlayerModel` feeds it views and times. Keys are kept in recording order; `end` merges them into the keyframe list.
struct RecordingSession {
    /// The camera at one instant (yaw radians, pitch radians, vertical fov degrees).
    struct View: Equatable {
        var yaw: Float, pitch: Float, fov: Float
        init(yaw: Float, pitch: Float, fov: Float) { self.yaw = yaw; self.pitch = pitch; self.fov = fov }
    }

    /// At most one recorded key per interval while the gesture continues (about 4 per second).
    static let interval = 0.25
    /// Existing keys this close to the covered range are replaced, like `PlayerModel.setKey` does (not duplicated).
    static let replaceDistance = 0.15

    private(set) var startTime: Double
    private(set) var recorded: [Keyframe] = []
    private var lastTime: Double

    /// Starts the gesture with an anchor key holding the view as it was BEFORE the first move.
    init(time: Double, view: View) {
        startTime = max(0, time)
        lastTime = startTime
        add(time: time, view: view)
    }

    /// Adds a key when at least `interval` has passed (either direction) since the last recorded one. Returns whether it did.
    @discardableResult
    mutating func sample(time: Double, view: View) -> Bool {
        guard time.isFinite, abs(time - lastTime) >= Self.interval else { return false }
        add(time: time, view: view)
        return true
    }

    /// Adds the final key and returns `keys` with everything inside the covered time range (min...max of all recorded
    /// times, padded by `replaceDistance`) replaced by the recorded keys; keys outside are untouched. Sorted, unique times.
    mutating func end(time: Double, view: View, keys: [Keyframe]) -> [Keyframe] {
        if time.isFinite { add(time: time, view: view) }
        guard let lo = recorded.map(\.time).min(), let hi = recorded.map(\.time).max() else { return keys }
        let kept = keys.filter { $0.time < lo - Self.replaceDistance || $0.time > hi + Self.replaceDistance }
        return (kept + recorded).sorted { $0.time < $1.time }
    }

    private mutating func add(time: Double, view: View) {
        guard time.isFinite else { return }
        let t = max(0, time)
        lastTime = t
        let yaw = wrapAngle(view.yaw)
        let limit = Float(KeyframeEdit.pitchLimit * .pi / 180)
        let pitch = max(-limit, min(limit, view.pitch))
        let fov = max(Float(KeyframeEdit.fovRange.lowerBound), min(Float(KeyframeEdit.fovRange.upperBound), view.fov))
        if let i = recorded.firstIndex(where: { abs($0.time - t) < KeyframeEdit.minSpacing }) {
            recorded[i] = Keyframe(id: recorded[i].id, time: recorded[i].time, yaw: yaw, pitch: pitch, fov: fov)
        } else {
            recorded.append(Keyframe(time: t, yaw: yaw, pitch: pitch, fov: fov))
        }
    }
}
