import XCTest
@testable import CC360Framer

final class BatchQueueTests: XCTestCase {
    private func u(_ s: String) -> URL { URL(fileURLWithPath: "/v/" + s) }
    private func queue(_ names: [String]) -> BatchQueue {
        var q = BatchQueue()
        for n in names { q.add([u(n)], fm: FakeFM()) }
        return q
    }

    /// FileManager reporting every path as an existing file.
    final class FakeFM: FileManager {
        override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            isDirectory?.pointee = false; return true
        }
    }

    func testScanRecursiveDedupeAndFilter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bq-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("sub/\(Sidecar.folderName)"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for p in ["b.360", "a.360", "sub/c.360", "sub/deep/d.360", "e.mp4", "sub/\(Sidecar.folderName)/x.360", ".hidden.360"] {
            fm.createFile(atPath: root.appendingPathComponent(p).path, contents: Data())
        }
        var q = BatchQueue()
        XCTAssertEqual(q.add([root, root.appendingPathComponent("a.360")]), 4)
        XCTAssertEqual(q.items.map { $0.url.lastPathComponent }, ["a.360", "b.360", "c.360", "d.360"])
        XCTAssertEqual(q.add([root.appendingPathComponent("sub/c.360"), root.appendingPathComponent("e.mp4"), root.appendingPathComponent("nope.360")]), 0)
        XCTAssertEqual(q.items.count, 4)
    }

    func testMoveReorder() {
        var q = queue(["a.360", "b.360", "c.360", "d.360"])
        func names() -> String { q.items.map { $0.url.lastPathComponent.prefix(1) }.joined() }
        q.move(from: IndexSet(integer: 0), to: 3)   // a before d
        XCTAssertEqual(names(), "bcad")
        q.move(from: IndexSet(integer: 3), to: 0)   // d to front
        XCTAssertEqual(names(), "dbca")
        q.move(from: IndexSet([0, 1]), to: 4)       // append two
        XCTAssertEqual(names(), "cadb")
        q.move(from: IndexSet(integer: 1), to: 2)   // no-op position
        XCTAssertEqual(names(), "cadb")
    }

    func testRemoveKeepsActive() {
        var q = queue(["a.360", "b.360"])
        let first = q.items[0].id
        q.start()
        let active = q.beginNext()
        XCTAssertEqual(active, first)
        q.remove([first, q.items[1].id])
        XCTAssertEqual(q.items.count, 1)
        q.clear()
        XCTAssertEqual(q.items.count, 1)
        q.setState(first, .done)
        q.clear()
        XCTAssertTrue(q.items.isEmpty)
    }

    func testRunPauseResume() {
        var q = queue(["a.360", "b.360", "c.360"])
        XCTAssertTrue(q.start())
        XCTAssertFalse(q.start())
        let a = q.beginNext()!
        q.pause()
        XCTAssertEqual(q.runState, .pausing)
        q.setState(a, .done)
        XCTAssertNil(q.beginNext())
        XCTAssertEqual(q.runState, .paused)
        XCTAssertFalse(q.isRunning)
        XCTAssertTrue(q.start())
        let b = q.beginNext()!
        q.setState(b, .failed("x"))
        let c = q.beginNext()!
        q.setState(c, .done)
        XCTAssertNil(q.beginNext())
        XCTAssertEqual(q.runState, .idle)
        XCTAssertTrue(q.hasFailed)
        // Retry: only the failed item runs again, done ones are skipped.
        XCTAssertTrue(q.start())
        XCTAssertEqual(q.beginNext(), b)
        XCTAssertNil({ q.setState(b, .done); return q.beginNext() }())
        XCTAssertEqual(q.runState, .idle)
        XCTAssertFalse(q.start())
    }

    func testPauseOnLastItemEndsIdle() {
        var q = queue(["a.360"])
        q.start()
        let a = q.beginNext()!
        q.pause()
        q.setState(a, .done)
        XCTAssertNil(q.beginNext())
        XCTAssertEqual(q.runState, .idle)
    }

    func testResumeWhilePausing() {
        var q = queue(["a.360", "b.360"])
        q.start()
        _ = q.beginNext()
        q.pause()
        XCTAssertFalse(q.start())
        XCTAssertEqual(q.runState, .running)
    }

    func testOutputNaming() {
        let folder = URL(fileURLWithPath: "/out")
        let src = u("GS010001.360")
        XCTAssertEqual(BatchQueue.outputURL(for: src, in: folder, ext: "mp4", exists: { _ in false }).lastPathComponent, "GS010001-reframed.mp4")
        let taken: Set<String> = ["/out/GS010001-reframed.mp4"]
        XCTAssertEqual(BatchQueue.outputURL(for: src, in: folder, ext: "mp4", taken: taken, exists: { _ in false }).lastPathComponent, "GS010001-reframed-2.mp4")
        let onDisk: Set<String> = ["/out/GS010001-reframed.mov", "/out/GS010001-reframed-2.mov"]
        XCTAssertEqual(BatchQueue.outputURL(for: src, in: folder, ext: "mov", exists: { onDisk.contains($0.path) }).lastPathComponent, "GS010001-reframed-3.mov")
        // Same file name from two folders gets distinct outputs.
        var q = queue(["a.360"])
        let id = q.items[0].id
        q.setOutput(id, BatchQueue.outputURL(for: u("x/GS1.360"), in: folder, ext: "mp4", exists: { _ in false }))
        XCTAssertEqual(BatchQueue.outputURL(for: u("y/GS1.360"), in: folder, ext: "mp4", taken: q.takenOutputs, exists: { _ in false }).lastPathComponent, "GS1-reframed-2.mp4")
    }

    func testProgress() {
        var q = queue(["a.360", "b.360"])
        XCTAssertEqual(q.overallProgress(export: true), 0)
        q.setState(q.items[0].id, .done)
        XCTAssertEqual(q.overallProgress(export: true), 0.5, accuracy: 1e-9)
        q.setState(q.items[1].id, .exporting(0.5))
        XCTAssertEqual(q.overallProgress(export: true), 0.875, accuracy: 1e-9)
        XCTAssertLessThan(BatchQueue.fraction(.analysing(1), export: false), 1)
    }
}
