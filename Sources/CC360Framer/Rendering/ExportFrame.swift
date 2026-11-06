import Foundation

/// Where the exported frame sits inside the preview.
///
/// Preview and export share the vertical field of view, so the horizontal extent changes with the aspect. With preview aspect P and export aspect A (width / height) the frame is
/// `A / P` of the preview width when A < P (full height), and the full width with `P / A` of the height when A > P.
enum ExportFrame {
    /// Half extents in normalised device coordinates (the full preview is -1...1 on both axes).
    static func halfExtent(previewAspect p: Double, exportAspect a: Double) -> (x: Double, y: Double) {
        guard p > 0, a > 0, p.isFinite, a.isFinite else { return (1, 1) }
        return a < p ? (a / p, 1) : (1, p / a)
    }
}
