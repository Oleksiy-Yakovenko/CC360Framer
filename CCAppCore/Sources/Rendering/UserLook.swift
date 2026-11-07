/// Decides which view input counts as the user deliberately moving the camera
/// (and so switches Auto follow off). Trackpad momentum and zero-delta events are noise.
enum UserLook {
    static func dragCounts(deltaX: Double, deltaY: Double) -> Bool {
        deltaX != 0 || deltaY != 0
    }

    static func scrollCounts(deltaY: Double, inMomentum: Bool) -> Bool {
        !inMomentum && deltaY != 0
    }

    static func magnifyCounts(magnification: Double) -> Bool {
        magnification != 0
    }
}
