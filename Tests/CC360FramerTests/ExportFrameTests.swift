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

    func testPreviewFovScaleNarrowWideEqualDegenerate() {
        // Narrow export (A < P): the frame has full height, nothing to rescale.
        XCTAssertEqual(ExportFrame.previewFovScale(previewAspect: 16.0 / 9, exportAspect: 1), 1, accuracy: 1e-12)
        // Wide export (A > P): frame height P / A, so the preview zooms out by A / P.
        XCTAssertEqual(ExportFrame.previewFovScale(previewAspect: 1, exportAspect: 16.0 / 9), 16.0 / 9, accuracy: 1e-12)
        XCTAssertEqual(ExportFrame.previewFovScale(previewAspect: 1.2, exportAspect: 2.4), 2, accuracy: 1e-12)
        XCTAssertEqual(ExportFrame.previewFovScale(previewAspect: 1.5, exportAspect: 1.5), 1, accuracy: 1e-12)
        XCTAssertEqual(ExportFrame.previewFovScale(previewAspect: 0, exportAspect: 1), 1)
        XCTAssertEqual(ExportFrame.previewFovScale(previewAspect: 1, exportAspect: .nan), 1)
    }

    /// The guide rectangle shows exactly the exported field of view, for any window shape.
    func testFrameCoversExportedFieldOfView() {
        let fov = 70.0
        let tanHalf = tan(fov * .pi / 360)
        for (p, a) in [(1.8, 1.0), (0.6, 16.0 / 9), (1.2, 0.8), (1.0, 1.0), (2.5, 9.0 / 16), (0.5, 4.0 / 3)] {
            let h = ExportFrame.halfExtent(previewAspect: p, exportAspect: a)
            let tanPreview = tanHalf * ExportFrame.previewFovScale(previewAspect: p, exportAspect: a)
            // Vertical and horizontal tangents at the frame edge equal the export's (export: tan(fov/2) and A * tan(fov/2)).
            XCTAssertEqual(h.y * tanPreview, tanHalf, accuracy: 1e-12, "\(p) \(a)")
            XCTAssertEqual(h.x * p * tanPreview, a * tanHalf, accuracy: 1e-12, "\(p) \(a)")
            // The frame fits in the view and touches it on at least one axis.
            XCTAssertLessThanOrEqual(h.x, 1 + 1e-12); XCTAssertLessThanOrEqual(h.y, 1 + 1e-12)
            XCTAssertEqual(max(h.x, h.y), 1, accuracy: 1e-12)
        }
    }

    func testPreviewFovDegrees() {
        XCTAssertEqual(ExportFrame.previewFovDegrees(fov: 70, previewAspect: 2, exportAspect: 1), 70, accuracy: 1e-9)
        let wide = ExportFrame.previewFovDegrees(fov: 70, previewAspect: 1, exportAspect: 16.0 / 9)
        XCTAssertGreaterThan(wide, 70)
        XCTAssertEqual(tan(wide * .pi / 360), tan(70 * .pi / 360) * 16.0 / 9, accuracy: 1e-9)
    }

    func testPixelRectIsCentredWithExportAspect() {
        let r = ExportFrame.pixelRect(width: 1600, height: 900, exportAspect: 1)
        XCTAssertEqual(r.width, 900, accuracy: 1e-9); XCTAssertEqual(r.height, 900, accuracy: 1e-9)
        XCTAssertEqual(r.x, 350, accuracy: 1e-9); XCTAssertEqual(r.y, 0, accuracy: 1e-9)
        let w = ExportFrame.pixelRect(width: 1000, height: 1000, exportAspect: 2)
        XCTAssertEqual(w.width, 1000, accuracy: 1e-9); XCTAssertEqual(w.height, 500, accuracy: 1e-9)
        XCTAssertEqual(w.y, 250, accuracy: 1e-9)
        for (pw, ph, a) in [(1600.0, 900.0, 1.0), (500.0, 1200.0, 16.0 / 9), (800.0, 800.0, 0.8)] {
            let q = ExportFrame.pixelRect(width: pw, height: ph, exportAspect: a)
            XCTAssertEqual(q.width / q.height, a, accuracy: 1e-9)
        }
        let z = ExportFrame.pixelRect(width: 0, height: 0, exportAspect: 1)
        XCTAssertEqual(z.width, 0); XCTAssertEqual(z.height, 0)
    }

    func testOverlayLayoutInsideFrame() {
        // A 1:1 frame of 900 px centred in a 1600x900 view: a bottom-left overlay sits at the frame's corner plus the margin.
        let frame = (x: Float(350), y: Float(0), width: Float(900), height: Float(900))
        let r = OverlayLayout.rect(texWidth: 300, texHeight: 100, targetWidth: 1600, targetHeight: 900, frame: frame,
                                   placement: .bottomLeft, size: .referenceShort(900))
        let margin = (900 * OverlayLayout.margin).rounded()
        XCTAssertEqual((r.x0 + 1) * 800, 350 + margin, accuracy: 1e-3)
        XCTAssertEqual((r.y0 + 1) * 450, margin, accuracy: 1e-3)
        XCTAssertEqual((r.x1 - r.x0) * 800, 300, accuracy: 1e-3)
        XCTAssertEqual((r.y1 - r.y0) * 450, 100, accuracy: 1e-3)
        // Same as the plain layout of a frame-sized target, shifted.
        let plain = OverlayLayout.rect(texWidth: 300, texHeight: 100, targetWidth: 900, targetHeight: 900, placement: .bottomLeft, size: .referenceShort(900))
        XCTAssertEqual((r.x0 + 1) * 800 - 350, (plain.x0 + 1) * 450, accuracy: 1e-3)
        // A full-target frame is the identity.
        let full = OverlayLayout.rect(texWidth: 300, texHeight: 100, targetWidth: 1600, targetHeight: 900, frame: (0, 0, 1600, 900), placement: .topRight, size: .referenceShort(900))
        let ref = OverlayLayout.rect(texWidth: 300, texHeight: 100, targetWidth: 1600, targetHeight: 900, placement: .topRight, size: .referenceShort(900))
        XCTAssertEqual(full.x0, ref.x0, accuracy: 1e-5); XCTAssertEqual(full.y1, ref.y1, accuracy: 1e-5)
    }
}
