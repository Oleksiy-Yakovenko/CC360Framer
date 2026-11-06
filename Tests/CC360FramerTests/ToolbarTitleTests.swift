import XCTest
@testable import CC360Framer

final class ToolbarTitleTests: XCTestCase {
    func testWithFile() {
        XCTAssertEqual(ToolbarTitle.text(appName: "CC360Framer", fileName: "GS010033.360"), "CC360Framer - GS010033.360")
    }
    func testWithoutFile() {
        XCTAssertEqual(ToolbarTitle.text(appName: "CC360Framer", fileName: nil), "CC360Framer")
        XCTAssertEqual(ToolbarTitle.text(appName: "CC360Framer", fileName: ""), "CC360Framer")
    }
}
