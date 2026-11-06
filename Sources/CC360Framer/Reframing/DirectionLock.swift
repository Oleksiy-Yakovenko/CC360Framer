import Foundation

/// "Direction lock": the user rotates the preview to the direction they consider forward (the camera is often mounted at an
/// angle to the vehicle) and with the lock on that yaw (stabilised frame, radians) is forward everywhere. Pure logic.
enum DirectionLock {
    /// Seconds after the last drag event before the view's yaw is taken as the user's direction.
    static let settleDelay = 0.4
    /// Smaller changes of the recorded yaw are ignored (no save for nothing).
    static let epsilon: Float = 1e-4

    /// The forward closure for the path builders. With the lock on it is the constant `lockedYaw` for every time and beats
    /// the Forward setting and the estimate; with the lock off it is `TravelDirection.forwardYaw` (nil = camera front).
    static func forwardYaw(lock: Bool, lockedYaw: Float, mode: TravelDirection.ForwardMode, estimate: TravelDirection.Estimate?,
                           stabilizer: Stabilizer?) -> ((Double) -> Float)? {
        if lock { let y = wrapAngle(lockedYaw); return { _ in y } }
        return TravelDirection.forwardYaw(mode: mode, estimate: estimate, stabilizer: stabilizer)
    }

    /// The yaw to record once the view has settled: the wrapped view yaw if it differs from the stored one, else nil.
    static func settledYaw(viewYaw: Float, stored: Float) -> Float? {
        let y = wrapAngle(viewYaw)
        return abs(wrapAngle(y - stored)) > epsilon ? y : nil
    }

    /// Debounce state of the drag events: yaw is read only for drags (scroll and pinch change the fov, not the direction).
    struct Settle: Equatable {
        private(set) var lastDrag: Double?

        mutating func noteDrag(at now: Double) { lastDrag = now }

        /// True when a drag happened and nothing newer than `settleDelay` has followed it; consumes the pending drag.
        mutating func takeIfSettled(at now: Double) -> Bool {
            guard let last = lastDrag, now - last >= DirectionLock.settleDelay - 1e-9 else { return false }
            lastDrag = nil
            return true
        }
    }

    /// "Direction lock: forward is 35 deg right of the camera front."
    static func summary(yaw: Float) -> String {
        let deg = Double(wrapAngle(yaw)) * 180 / .pi
        if abs(deg) < 0.5 { return "Direction lock: forward is the camera front." }
        return String(format: "Direction lock: forward is %.0f deg %@ of the camera front.", abs(deg), deg > 0 ? "right" : "left")
    }
}
