import XCTest
@testable import CCAppCore

final class TabItemTests: XCTestCase {
    func testSymbolWinsWhenAvailable() {
        XCTAssertEqual(TabItem.display(symbolAvailable: true, title: "Export"), .symbol)
    }

    func testFallsBackToTitle() {
        XCTAssertEqual(TabItem.display(symbolAvailable: false, title: "Export"), .title("Export"))
    }
}
