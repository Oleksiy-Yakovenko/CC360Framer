import XCTest
@testable import CCAppCore

final class SidecarTests: XCTestCase {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testURLInFolder() {
        let v = URL(fileURLWithPath: "/a/b/GS01.360")
        XCTAssertEqual(Sidecar.url(for: v, kind: "reframe").path, "/a/b/CC360Framer.sidecars/GS01.360.reframe.json")
    }

    func testWriteCreatesFolderLoadDoesNot() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let v = d.appendingPathComponent("x.360")
        XCTAssertNil(Sidecar.read(for: v, kind: "project"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.appendingPathComponent(Sidecar.folderName).path))
        XCTAssertTrue(Sidecar.write(Data("hi".utf8), for: v, kind: "project"))
        XCTAssertEqual(Sidecar.read(for: v, kind: "project"), Data("hi".utf8))
    }

    func testLegacyFallbackAndFolderWins() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let v = d.appendingPathComponent("x.360")
        try Data("old".utf8).write(to: Sidecar.legacyURL(for: v, kind: "location"))
        XCTAssertEqual(Sidecar.read(for: v, kind: "location"), Data("old".utf8))
        Sidecar.write(Data("new".utf8), for: v, kind: "location")
        XCTAssertEqual(Sidecar.read(for: v, kind: "location"), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: Sidecar.legacyURL(for: v, kind: "location")), Data("old".utf8)) // untouched
    }
}
