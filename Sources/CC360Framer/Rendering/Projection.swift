import Foundation

/// Layout of a GoPro `.360` frame once both video tracks are stacked vertically
/// (track 0 on top, track 1 below): 5888x3840.
///
/// Each track is a ring of three 90° EAC faces (3 x 1920 = 5760 px) stored as three
/// overlapping tiles of 992 / 3904 / 992 px (64 px overlap at each of the two seams).
/// Track 0 is the ring around the vertical axis (left, front, right); track 1 is the
/// ring around the horizontal axis (bottom, back, top), stored rotated by 90°.
enum Layout {
    static let trackWidth = 5888
    static let trackHeight = 1920
    static let stackedHeight = trackHeight * 2
}

/// Look direction in the shared view state. Read from the render thread, written by UI.
final class ViewState {
    var yaw: Float = 0            // radians, + = look right
    var pitch: Float = 0          // radians, + = look up
    var fovDegrees: Float = 70    // vertical field of view
    /// Orientation switches (+1 / -1) kept configurable while the layout is being verified:
    /// track 0 ring direction, track 0 cross direction, track 1 ring direction, track 1 cross direction.
    var cfg = SIMD4<Float>(1, 1, 1, 1)
    /// 0 = rectilinear view, 1 = equirectangular (debug).
    var mode: Float = 0
    /// Horizon-locked virtual camera; nil = look straight through the camera body's axes.
    var stabilizer: Stabilizer?
    /// Time of the frame being drawn, used to look up the stabilised camera.
    var frameTime: Double = 0
    /// Preview only: aspect (width / height) of the export frame to outline; nil = hidden.
    /// True while a global fov is set: scroll/pinch zoom is ignored (the slider in the Export tab is the control).
    var fovLocked = false
    var exportFrameAspect: Double?
    /// Called when the user takes manual control of the view (drag/zoom).
    var onUserLook: (() -> Void)?

    func reset() { yaw = 0; pitch = 0; fovDegrees = 70 }
}

struct Uniforms {
    var yaw: Float
    var pitch: Float
    var tanHalfFov: Float
    var aspect: Float
    var cfg: SIMD4<Float>
    var mode: Float
    var yuv: Float               // 1 when the frame is biplanar YCbCr (full range, BT.709)
    var right: SIMD4<Float>      // virtual camera axes in body coordinates (w unused)
    var up: SIMD4<Float>
    var forward: SIMD4<Float>
}
