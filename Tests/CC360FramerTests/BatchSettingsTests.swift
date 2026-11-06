import XCTest
@testable import CC360Framer

final class BatchSettingsTests: XCTestCase {
    func testRoundTripAndDefaults() throws {
        var s = BatchSettings()
        s.forceReanalyse = true; s.export = false; s.style = .scenery
        s.outputFolder = URL(fileURLWithPath: "/tmp/out", isDirectory: true)
        s.exportSettings.crossfade = 1.25
        let back = try JSONDecoder().decode(BatchSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let empty = try JSONDecoder().decode(BatchSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(empty.export); XCTAssertFalse(empty.forceReanalyse); XCTAssertNil(empty.outputFolder); XCTAssertEqual(empty.style, .follow)
    }

    func testStartProblem() {
        var s = BatchSettings()
        XCTAssertNotNil(s.startProblem)
        s.export = false
        XCTAssertNil(s.startProblem)
        s.export = true; s.outputFolder = URL(fileURLWithPath: "/tmp")
        XCTAssertNil(s.startProblem)
    }

    func testPersistence() {
        let d = UserDefaults(suiteName: "bs-\(UUID().uuidString)")!
        var s = BatchSettings(); s.style = .scenery
        s.save(d)
        XCTAssertEqual(BatchSettings.load(d).style, .scenery)
    }
}
