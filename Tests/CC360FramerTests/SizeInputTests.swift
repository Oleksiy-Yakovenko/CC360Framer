import XCTest
@testable import CC360Framer

final class SizeInputTests: XCTestCase {
    private let card = LocationCardStyle.sizeRange

    func testParsesPlainAndDecoratedNumbers() {
        XCTAssertEqual(SizeInput.parse("64", range: card), 64)
        XCTAssertEqual(SizeInput.parse("  96 ", range: card), 96)
        XCTAssertEqual(SizeInput.parse("72pt", range: card), 72)
        XCTAssertEqual(SizeInput.parse("72 px", range: card), 72)
        XCTAssertEqual(SizeInput.parse("5,5%", range: 2...15, step: 0.1), 5.5)
        XCTAssertEqual(SizeInput.parse("64.4", range: card), 64)   // rounded to the step
    }

    func testClampsToRange() {
        XCTAssertEqual(SizeInput.parse("1", range: card), 8)
        XCTAssertEqual(SizeInput.parse("9999", range: card), 400)
        XCTAssertEqual(SizeInput.parse("-20", range: card), 8)
        XCTAssertEqual(SizeInput.parse("0.5", range: 2...15, step: 0.1), 2)
        XCTAssertEqual(SizeInput.parse("40", range: 2...15, step: 0.1), 15)
    }

    func testInvalidTextIsNil() {
        for t in ["", "  ", "abc", "12abc", "nan", "inf", "1e999", "%", "6 4"] {
            XCTAssertNil(SizeInput.parse(t, range: card), "'\(t)'")
        }
    }

    func testStepRoundingHasNoFloatNoise() {
        XCTAssertEqual(SizeInput.parse("5.5", range: 2...15, step: 0.1), 5.5)
        XCTAssertEqual(SizeInput.parse("5.5", range: 2...15, step: 0.1)! / 100, 0.055)
        XCTAssertEqual(SizeInput.parse("7.26", range: 2...15, step: 0.1), 7.3)
    }

    func testFormat() {
        XCTAssertEqual(SizeInput.format(64), "64")
        XCTAssertEqual(SizeInput.format(5.5), "5.5")
        XCTAssertEqual(SizeInput.format(3), "3")
    }

    func testPresetsAreInsideRangeAndSorted() {
        XCTAssertEqual(LocationCardStyle.sizePresets, LocationCardStyle.sizePresets.sorted())
        XCTAssertTrue(LocationCardStyle.sizePresets.allSatisfy { LocationCardStyle.sizeRange.contains($0) })
        XCTAssertTrue(LocationCardStyle.sizePresets.contains(LocationCardStyle.defaultBaseSize))
    }

    /// Regression: a typed non-preset value must win over the stale selected preset.
    func testChosenTextPrefersPickThenEditorThenString() {
        XCTAssertEqual(SizeInput.chosenText(pickedItem: "64", editorText: "24", stringValue: "24"), "64")
        XCTAssertEqual(SizeInput.chosenText(pickedItem: nil, editorText: "50", stringValue: "24"), "50")
        XCTAssertEqual(SizeInput.chosenText(pickedItem: nil, editorText: nil, stringValue: "50"), "50")
    }
}
