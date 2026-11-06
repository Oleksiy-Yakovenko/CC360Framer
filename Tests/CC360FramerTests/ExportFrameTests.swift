import XCTest
@testable import CC360Framer

final class ExportFrameTests: XCTestCase {
    func testNarrowerExportKeepsHeight() {
        let r = ExportFrame.halfExtent(previewAspect: 16.0 / 9, exportAspect: 1)
        XCTAssertEqual(r.x, 9.0 / 16, accuracy: 1e-9); XCTAssertEqual(r.y, 1)
        let v = ExportFrame.halfExtent(previewAspect: 2, exportAspect: 9.0 / 16)
        XCTAssertEqual(v.x, 9.0 / 32, accuracy: 1e-9); XCTAssertEqual(v.y, 1)
    }

    func testWiderExportKeepsWidth() {
        let r = ExportFrame.halfExtent(previewAspect: 1, exportAspect: 16.0 / 9)
        XCTAssertEqual(r.x, 1); XCTAssertEqual(r.y, 9.0 / 16, accuracy: 1e-9)
    }

    func testSameAspectIsFullAndDegenerateInputIsSafe() {
        let r = ExportFrame.halfExtent(previewAspect: 1.5, exportAspect: 1.5)
        XCTAssertEqual(r.x, 1); XCTAssertEqual(r.y, 1)
        let z = ExportFrame.halfExtent(previewAspect: 0, exportAspect: 1)
        XCTAssertEqual(z.x, 1); XCTAssertEqual(z.y, 1)
    }

    func testFrameMatchesExportPixels() {
        // The frame's pixel aspect inside the preview equals the export aspect.
        for (p, a) in [(1.8, 1.0), (0.6, 16.0 / 9), (1.2, 0.8)] {
            let r = ExportFrame.halfExtent(previewAspect: p, exportAspect: a)
            XCTAssertEqual(r.x * p / r.y, a, accuracy: 1e-9)
        }
    }
}
