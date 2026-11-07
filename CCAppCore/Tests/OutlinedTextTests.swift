import XCTest
import AppKit
@testable import CCAppCore

final class OutlinedTextTests: XCTestCase {
    private func lines(_ texts: [String]) -> [OutlinedText.Line] {
        texts.map { OutlinedText.Line(text: $0, font: .systemFont(ofSize: 40, weight: .bold), fill: .white) }
    }

    func testBitmapGrowsByOutlinePadding() {
        let l = lines(["Hello"])
        let a = OutlinedText.bitmapSize(lines: l, gap: 0, pad: 10, outline: 0)
        let b = OutlinedText.bitmapSize(lines: l, gap: 0, pad: 10, outline: 4)
        XCTAssertEqual(b.w - a.w, 8)
        XCTAssertEqual(b.h - a.h, 8)
    }

    func testCaptionOutlineWidthIsPercentOfFontSize() {
        var s = CaptionStyle(); s.strokeWidth = 7
        XCTAssertEqual(CaptionOverlay.outlineWidth(s, fontPixels: 100), 7, accuracy: 1e-9)
        s.strokeWidth = 0
        XCTAssertEqual(CaptionOverlay.outlineWidth(s, fontPixels: 100), 0)
    }

    func testOutlineIsVisibleOutsideTheGlyphAndOpaqueFillInside() throws {
        let img = try XCTUnwrap(OutlinedText.image(lines: lines(["I"]), align: .left, gap: 0, pad: 10, outline: 5, stroke: .black))
        // Premultiplied BGRA: count opaque black (outline) and opaque white (fill) pixels.
        let ctx = try XCTUnwrap(CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var black = 0, white = 0
        for y in 0..<img.height { for x in 0..<img.width {
            let q = p + y * ctx.bytesPerRow + x * 4
            if q[3] == 255 { if q[0] > 250 { white += 1 } else if q[0] < 5 { black += 1 } }
        } }
        XCTAssertGreaterThan(white, 50)
        XCTAssertGreaterThan(black, 50)
        // Nothing touches the bitmap edge (no clipping).
        for x in 0..<img.width { XCTAssertEqual(p[x * 4 + 3], 0); XCTAssertEqual(p[(img.height - 1) * ctx.bytesPerRow + x * 4 + 3], 0) }
    }

    func testMultiLineCaptionIsTallerAndAlignmentKeepsSize() throws {
        var l = CaptionStyle(); l.placement = .bottomLeft
        var r = CaptionStyle(); r.placement = .bottomRight
        let a = try XCTUnwrap(CaptionOverlay.image(text: "Hello\nHi", style: l, short: 1080))
        let b = try XCTUnwrap(CaptionOverlay.image(text: "Hello\nHi", style: r, short: 1080))
        let one = try XCTUnwrap(CaptionOverlay.image(text: "Hello", style: l, short: 1080))
        XCTAssertEqual(a.width, b.width); XCTAssertEqual(a.height, b.height)
        XCTAssertGreaterThan(a.height, one.height)
    }
}
