import XCTest
@testable import CC360Framer

final class DocumentStateTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "CC360FramerTests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testFrameNameIsPerFile() {
        let a = DocumentKeys.frameName(for: URL(fileURLWithPath: "/tmp/a.360"))
        let b = DocumentKeys.frameName(for: URL(fileURLWithPath: "/tmp/b.360"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, DocumentKeys.frameName(for: URL(fileURLWithPath: "/tmp/x/../a.360")))
    }

    func testSplitLayoutRoundTrip() {
        let store = SplitLayoutStore(defaults: makeDefaults())
        let url = URL(fileURLWithPath: "/tmp/a.360")
        XCTAssertNil(store.load(for: url))
        let layout = SplitLayout(left: 300, inspector: 400, leftCollapsed: true, inspectorCollapsed: false)
        store.save(layout, for: url)
        XCTAssertEqual(store.load(for: url), layout)
        XCTAssertNil(store.load(for: URL(fileURLWithPath: "/tmp/b.360")))
    }

    func testSplitLayoutIgnoresGarbage() {
        let d = makeDefaults()
        let url = URL(fileURLWithPath: "/tmp/a.360")
        d.set(Data("nope".utf8), forKey: DocumentKeys.layoutKey(for: url))
        XCTAssertNil(SplitLayoutStore(defaults: d).load(for: url))
    }

    func testFittedClampsToRanges() {
        let l = SplitLayout(left: 10, inspector: 5000, leftCollapsed: false, inspectorCollapsed: false).fitted(totalWidth: 3000)
        XCTAssertEqual(l.left, 200)
        XCTAssertEqual(l.inspector, 600)
        let nan = SplitLayout(left: .nan, inspector: .infinity, leftCollapsed: false, inspectorCollapsed: false).fitted(totalWidth: 3000)
        XCTAssertEqual(nan.left, 260)
        XCTAssertEqual(nan.inspector, 320)
    }

    func testFittedKeepsCentreWidth() {
        // 1000 wide: 1000 - 420 = 580 for the panes; 300 + 500 is too much, the inspector gives way first.
        let l = SplitLayout(left: 300, inspector: 500, leftCollapsed: false, inspectorCollapsed: false).fitted(totalWidth: 1000)
        XCTAssertEqual(l.left, 300)
        XCTAssertEqual(l.inspector, 280)
        // Very narrow: the left pane shrinks too, but not below its minimum.
        let n = SplitLayout(left: 300, inspector: 500, leftCollapsed: false, inspectorCollapsed: false).fitted(totalWidth: 800)
        XCTAssertEqual(n.left, 200)
        XCTAssertEqual(n.inspector, 280)
    }

    func testFittedIgnoresCollapsedPanes() {
        let l = SplitLayout(left: 300, inspector: 500, leftCollapsed: true, inspectorCollapsed: false).fitted(totalWidth: 1000)
        XCTAssertEqual(l.inspector, 500)
        XCTAssertTrue(l.leftCollapsed)
    }

    func testOpenDocumentsStore() {
        let store = OpenDocumentsStore(defaults: makeDefaults())
        let a = URL(fileURLWithPath: "/tmp/a.360"), b = URL(fileURLWithPath: "/tmp/b.360")
        store.add(a); store.add(b); store.add(a)
        XCTAssertEqual(store.urls, [a, b])
        store.remove(a)
        XCTAssertEqual(store.urls, [b])
        store.remove(a)
        XCTAssertEqual(store.urls, [b])
    }

    func testRestorableDropsMissingFiles() {
        let store = OpenDocumentsStore(defaults: makeDefaults())
        let a = URL(fileURLWithPath: "/tmp/a.360"), b = URL(fileURLWithPath: "/tmp/gone.360"), c = URL(fileURLWithPath: "/tmp/c.360")
        [a, b, c].forEach(store.add)
        let result = store.restorable { $0 != b }
        XCTAssertEqual(result, [a, c])
        XCTAssertEqual(store.urls, [a, c])
    }

    func testRecentEntryFormatting() {
        let e = RecentDocumentEntry(url: URL(fileURLWithPath: "/Users/me/Movies/GoPro/GS010074.360"), home: "/Users/me")
        XCTAssertEqual(e.name, "GS010074")
        XCTAssertEqual(e.location, "~/Movies/GoPro")
        XCTAssertEqual(RecentDocumentEntry.abbreviate("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(RecentDocumentEntry.abbreviate("/Users/mex/a", home: "/Users/me"), "/Users/mex/a")
        XCTAssertEqual(RecentDocumentEntry(url: URL(fileURLWithPath: "/Volumes/X/a.360"), home: "/Users/me").location, "/Volumes/X")
    }

    func testRecentEntriesFilterAndLimit() {
        let urls = (0..<30).map { URL(fileURLWithPath: "/tmp/f\($0).360") } + [URL(fileURLWithPath: "/tmp/f1.360")]
        let all = RecentDocumentEntry.entries(from: urls, exists: { $0.lastPathComponent != "f0.360" })
        XCTAssertEqual(all.count, 20)
        XCTAssertEqual(all.first?.name, "f1")
        let few = RecentDocumentEntry.entries(from: [urls[1], urls[1], urls[2]], exists: { _ in true })
        XCTAssertEqual(few.map(\.name), ["f1", "f2"])
    }

    func testLaunchFileArgument() {
        let exists: (String) -> Bool = { $0 == "/tmp/a.360" }
        XCTAssertEqual(launchFileArgument(["app", "-NSDocumentRevisionsDebugMode", "YES", "/tmp/a.360"], exists: exists)?.path, "/tmp/a.360")
        XCTAssertNil(launchFileArgument(["app", "-psn_0_1"], exists: exists))
        XCTAssertNil(launchFileArgument(["/tmp/a.360"], exists: exists))   // the first element is the executable
    }
}
