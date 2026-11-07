import Foundation

/// Where the exported frame sits inside the preview.
///
/// With "Show export frame" on, the preview is rendered so that the frame is exactly the exported field of view: the frame is
/// the largest rectangle of the export aspect that fits in the view (`halfExtent`), and the preview's projection is scaled
/// by `previewFovScale` so the vertical field of view of the real export (`ViewState.fovDegrees`) spans exactly the frame's
/// height. What is inside the frame is then identical to the export for any window size; the dimmed surroundings show extra
/// context. With preview aspect P and export aspect A (width / height) the frame is `A / P` of the view width at full
/// height when A < P, and the full width at `P / A` of the height otherwise.
enum ExportFrame {
    /// Half extents in normalised device coordinates (the full preview is -1...1 on both axes).
    static func halfExtent(previewAspect p: Double, exportAspect a: Double) -> (x: Double, y: Double) {
        guard p > 0, a > 0, p.isFinite, a.isFinite else { return (1, 1) }
        return a < p ? (a / p, 1) : (1, p / a)
    }

    /// Factor for the preview's `tan(fov / 2)` so the frame spans the export's vertical field of view: `1 / hy`
    /// (1 when the frame is the full view height or the input is degenerate).
    static func previewFovScale(previewAspect p: Double, exportAspect a: Double) -> Double {
        1 / halfExtent(previewAspect: p, exportAspect: a).y
    }

    /// The vertical field of view (degrees) the preview is actually drawn with while the guide is on, for the real export fov.
    static func previewFovDegrees(fov: Double, previewAspect p: Double, exportAspect a: Double) -> Double {
        2 * atan(tan(fov * .pi / 360) * previewFovScale(previewAspect: p, exportAspect: a)) * 180 / .pi
    }

    /// The frame in pixels (origin bottom-left, y up) inside a view of the given size, centred.
    static func pixelRect(width: Double, height: Double, exportAspect a: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        guard width > 0, height > 0 else { return (0, 0, max(width, 0), max(height, 0)) }
        let h = halfExtent(previewAspect: width / height, exportAspect: a)
        let w = width * h.x, ht = height * h.y
        return ((width - w) / 2, (height - ht) / 2, w, ht)
    }
}
