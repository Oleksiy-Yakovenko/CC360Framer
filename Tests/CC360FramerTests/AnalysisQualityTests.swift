import XCTest
@testable import CC360Framer

final class AnalysisQualityTests: XCTestCase {
    func testViewsAndFov() {
        XCTAssertEqual(AnalysisQuality.fast.viewCount, 8); XCTAssertEqual(AnalysisQuality.fast.viewFov, 90)
        XCTAssertEqual(AnalysisQuality.medium.viewCount, 12); XCTAssertEqual(AnalysisQuality.medium.viewFov, 60)
        XCTAssertEqual(AnalysisQuality.best.viewCount, 16); XCTAssertEqual(AnalysisQuality.best.viewFov, 45)
        XCTAssertEqual(AnalysisQuality.allCases.map(\.rawValue), ["Fast", "Medium", "Best Quality (slowest)"])
        for q in AnalysisQuality.allCases { XCTAssertFalse(q.tooltip.isEmpty) }
    }

    func testAreaScale() {
        XCTAssertEqual(AnalysisQuality.fast.areaScale, 1, accuracy: 1e-6)
        XCTAssertEqual(AnalysisQuality.medium.areaScale, 4.0 / 9.0, accuracy: 1e-6)
        XCTAssertEqual(AnalysisQuality.best.areaScale, 0.25, accuracy: 1e-6)
    }

    func testSideViews() {
        func excluded(_ q: AnalysisQuality) -> [Int] { (0..<q.viewCount).filter { !q.isSideView($0) } }
        XCTAssertEqual(excluded(.fast), [0, 4])
        XCTAssertEqual(excluded(.medium), [0, 1, 5, 6, 7, 11])
        XCTAssertEqual(excluded(.best), [0, 1, 7, 8, 9, 15])
    }

    func testSideViewWrapsNegativeYaw() {
        XCTAssertFalse(AnalysisQuality.isSideView(centreYaw: -0.1))
        XCTAssertTrue(AnalysisQuality.isSideView(centreYaw: -.pi / 2))
    }

    func testStoredDecodingIsLenient() {
        XCTAssertEqual(AnalysisQuality(stored: "Medium"), .medium)
        XCTAssertEqual(AnalysisQuality(stored: "junk"), .fast)
        XCTAssertEqual(AnalysisQuality(stored: nil), .fast)
    }

    func testBatchSettingsQuality() throws {
        var s = BatchSettings(); s.analysisQuality = .best
        XCTAssertEqual(try JSONDecoder().decode(BatchSettings.self, from: JSONEncoder().encode(s)).analysisQuality, .best)
        XCTAssertEqual(try JSONDecoder().decode(BatchSettings.self, from: Data("{}".utf8)).analysisQuality, .fast)
        XCTAssertEqual(try JSONDecoder().decode(BatchSettings.self, from: Data(#"{"analysisQuality":"x"}"#.utf8)).analysisQuality, .fast)
    }
}
