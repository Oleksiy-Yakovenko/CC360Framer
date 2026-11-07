import Foundation

/// Pure helpers for the per-document UI state (window frame names, split view layout), the list of open documents that is
/// reopened at launch and the entries of the welcome window. Nothing here touches AppKit windows, so it is unit tested.

enum DocumentKeys {
    /// Name under which AppKit saves the window frame of a document.
    static func frameName(for url: URL) -> String { "CC360Document:" + url.standardizedFileURL.path }
    static func layoutKey(for url: URL) -> String { "CC360Layout:" + url.standardizedFileURL.path }
}

/// Widths of the two side panes of a document window and whether they are collapsed. Saved per file.
struct SplitLayout: Codable, Equatable {
    static let leftRange: ClosedRange<Double> = 200...400
    static let inspectorRange: ClosedRange<Double> = 280...600
    static let centerMinimum: Double = 420
    static let standard = SplitLayout(left: 260, inspector: 320, leftCollapsed: false, inspectorCollapsed: false)

    var left: Double
    var inspector: Double
    var leftCollapsed: Bool
    var inspectorCollapsed: Bool

    /// The widths limited to the panes' ranges, and reduced (inspector first) so that the centre keeps its minimum
    /// width in a window of `totalWidth`. Collapsed panes take no room. Non-finite widths fall back to the standard ones.
    func fitted(totalWidth: Double) -> SplitLayout {
        var r = self
        r.left = (left.isFinite ? left : Self.standard.left).clamped(to: Self.leftRange)
        r.inspector = (inspector.isFinite ? inspector : Self.standard.inspector).clamped(to: Self.inspectorRange)
        let available = totalWidth - Self.centerMinimum
        var excess = (r.leftCollapsed ? 0 : r.left) + (r.inspectorCollapsed ? 0 : r.inspector) - available
        if excess > 0, !r.inspectorCollapsed {
            let cut = min(excess, r.inspector - Self.inspectorRange.lowerBound)
            r.inspector -= cut
            excess -= cut
        }
        if excess > 0, !r.leftCollapsed { r.left = max(Self.leftRange.lowerBound, r.left - excess) }
        return r
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

/// Split layouts per file in `UserDefaults`.
struct SplitLayoutStore {
    var defaults: UserDefaults = .standard

    func load(for url: URL) -> SplitLayout? {
        guard let data = defaults.data(forKey: DocumentKeys.layoutKey(for: url)) else { return nil }
        return try? JSONDecoder().decode(SplitLayout.self, from: data)
    }

    func save(_ layout: SplitLayout, for url: URL) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: DocumentKeys.layoutKey(for: url))
    }
}

/// The files that have a window, in opening order, so they can be reopened after a relaunch. Files are added when their
/// document opens and removed when the user closes it (not while the app quits).
struct OpenDocumentsStore {
    var defaults: UserDefaults = .standard
    var key = "openDocuments"

    var paths: [String] { defaults.stringArray(forKey: key) ?? [] }
    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    private func normalized(_ url: URL) -> String { url.standardizedFileURL.path }

    func add(_ url: URL) {
        let path = normalized(url)
        var list = paths
        guard !list.contains(path) else { return }
        list.append(path)
        defaults.set(list, forKey: key)
    }

    func remove(_ url: URL) {
        let path = normalized(url)
        defaults.set(paths.filter { $0 != path }, forKey: key)
    }

    /// The files to reopen: those that still exist. The others are dropped from the stored list.
    @discardableResult
    func restorable(exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [URL] {
        let all = urls
        let existing = all.filter(exists)
        if existing.count != all.count { defaults.set(existing.map(normalized), forKey: key) }
        return existing
    }
}

/// One row of the welcome window.
struct RecentDocumentEntry: Equatable {
    let name: String
    /// The folder, with the home folder abbreviated to `~`.
    let location: String
    let url: URL

    init(url: URL, home: String = NSHomeDirectory()) {
        self.url = url
        name = url.deletingPathExtension().lastPathComponent
        location = Self.abbreviate(url.deletingLastPathComponent().path, home: home)
    }

    static func abbreviate(_ path: String, home: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Entries for the recent file URLs, most recent first: files that no longer exist are left out, as are repeats.
    static func entries(from urls: [URL], home: String = NSHomeDirectory(), limit: Int = 20,
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [RecentDocumentEntry] {
        var seen = Set<String>()
        var result: [RecentDocumentEntry] = []
        for url in urls where exists(url) && seen.insert(url.standardizedFileURL.path).inserted {
            result.append(RecentDocumentEntry(url: url, home: home))
            if result.count == limit { break }
        }
        return result
    }
}

extension RecentDocumentEntry {
    /// Menu titles for the entries: the file name, with the folder added when another entry has the same file name.
    static func menuTitles(_ entries: [RecentDocumentEntry]) -> [String] {
        let names = entries.map { $0.url.lastPathComponent }
        return zip(entries, names).map { entry, name in
            names.filter { $0 == name }.count > 1 ? "\(name) — \(entry.location)" : name
        }
    }
}

/// First command-line argument that names an existing file, if any (dev and headless runs open that file instead of
/// reopening the previous session).
func launchFileArgument(_ arguments: [String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
    arguments.dropFirst().first { !$0.hasPrefix("-") && exists($0) }.map { URL(fileURLWithPath: $0) }
}
