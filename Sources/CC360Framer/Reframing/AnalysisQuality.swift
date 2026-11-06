import Foundation

/// How densely the analysis looks around the horizon. More, narrower views make people look bigger to Vision,
/// so small and distant people (and groups) are found more often, at the price of analysis time.
enum AnalysisQuality: String, Codable, CaseIterable, Sendable {
    case fast = "Fast"
    case medium = "Medium"
    case best = "Best Quality (slowest)"

    static let defaultsKey = "analysisQuality"

    /// Level views rendered around the horizon per analysed frame.
    var viewCount: Int {
        switch self {
        case .fast: return 8
        case .medium: return 12
        case .best: return 16
        }
    }

    /// Vertical (= horizontal) field of view of each view in degrees.
    var viewFov: Float {
        switch self {
        case .fast: return 90
        case .medium: return 60
        case .best: return 45
        }
    }

    var tooltip: String {
        switch self {
        case .fast: return "8 views of 90°. Fastest (about 1x). Finds the rider and large nearby people."
        case .medium: return "12 views of 60°. About 1.5x the analysis time. Better at finding small and distant people and groups."
        case .best: return "16 views of 45°. About 1.8x the analysis time. Best at finding small and distant people and groups."
        }
    }

    /// Tooltip for the popup: what the setting does plus every entry.
    static var popupTip: String {
        "Analysis quality. Re-analyse to apply it.\n" + allCases.map { "\($0.rawValue): \($0.tooltip)" }.joined(separator: "\n")
    }

    /// Centre yaw (radians) of view `index`.
    func viewYaw(_ index: Int) -> Float { Float(index) * 2 * .pi / Float(viewCount) }

    /// Factor for the box-area term of a score so scores stay comparable across qualities: a narrower view makes
    /// the same subject fill more of the image, so the area is scaled by the ratio of the view's solid angle to the
    /// 90 degree reference view, (viewFov / 90)^2.
    static func areaScale(viewFov: Float) -> Float { (viewFov / 90) * (viewFov / 90) }
    var areaScale: Float { Self.areaScale(viewFov: viewFov) }

    /// Saliency is only requested for side views. Views centred within 45 degrees of straight ahead (yaw 0) or
    /// straight behind (yaw 180) are covered by the forward shot and the rider.
    static func isSideView(centreYaw: Float) -> Bool {
        let twoPi = 2 * Float.pi
        var y = centreYaw.truncatingRemainder(dividingBy: twoPi)
        if y < 0 { y += twoPi }
        let toFront = min(y, twoPi - y)
        let toBack = abs(y - Float.pi)
        // Small tolerance so exact 45 degree views (float noise) count as side views.
        let limit = Float.pi / 4 - 1e-4
        return !(toFront < limit || toBack < limit)
    }

    func isSideView(_ index: Int) -> Bool { Self.isSideView(centreYaw: viewYaw(index)) }

    /// Lenient decoding from a stored raw value.
    init(stored: String?) { self = stored.flatMap { AnalysisQuality(rawValue: $0) } ?? .fast }
}
