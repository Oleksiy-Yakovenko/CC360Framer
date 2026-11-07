import Foundation

/// One file in the batch list.
struct BatchItem: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case analysing(Double)
        case building
        case exporting(Double)
        case done
        case failed(String)

        var isActive: Bool {
            switch self {
            case .analysing, .building, .exporting: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let url: URL
    var state: State = .pending
    /// Output file chosen when the item starts (nil while pending or when only analysing).
    var output: URL?

    init(url: URL) { self.url = url }
}

/// Pure logic of the batch list: items, ordering, the start/pause state machine, folder scanning and output naming.
/// No AVFoundation or UI; `BatchRunner` drives it and `BatchWindowController` shows it.
struct BatchQueue: Equatable {
    enum RunState: Equatable {
        case idle
        case running
        /// Pause requested: the current item finishes, then the queue stops.
        case pausing
        case paused
    }

    private(set) var items: [BatchItem] = []
    private(set) var runState: RunState = .idle

    var isRunning: Bool { runState == .running || runState == .pausing }

    // MARK: Scanning

    static let fileExtension = "360"

    static func isVideo(_ url: URL) -> Bool { url.pathExtension.lowercased() == fileExtension }

    /// `.360` files from dropped/chosen URLs: files are taken as they are (if they have the extension), folders are
    /// scanned recursively (hidden files and the sidecar folders skipped), results sorted by path inside a folder.
    static func scan(_ urls: [URL], fm: FileManager = .default) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey],
                                            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var found: [URL] = []
                for case let f as URL in e {
                    if f.lastPathComponent == Sidecar.folderName { e.skipDescendants(); continue }
                    if isVideo(f), (try? f.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true { found.append(f) }
                }
                out += found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            } else if isVideo(url) {
                out.append(url)
            }
        }
        return out
    }

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: Editing

    /// Appends the `.360` files found in `urls` (folders scanned), ignoring those already listed or repeated. Returns the number added.
    @discardableResult
    mutating func add(_ urls: [URL], fm: FileManager = .default) -> Int {
        var known = Set(items.map { Self.key($0.url) })
        var added = 0
        for u in Self.scan(urls, fm: fm) where known.insert(Self.key(u)).inserted {
            items.append(BatchItem(url: u))
            added += 1
        }
        return added
    }

    /// Removes the listed items except the one being processed.
    mutating func remove(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) && !$0.state.isActive }
    }

    /// Removes everything that is not being processed.
    mutating func clear() { items.removeAll { !$0.state.isActive } }

    mutating func removeFinished() { items.removeAll { $0.state == .done } }

    /// Moves the items at `offsets` so that they end up before the item that is currently at `destination` (NSTableView drop
    /// semantics: `destination` counts in the list before the move; `items.count` appends).
    mutating func move(from offsets: IndexSet, to destination: Int) {
        let moving = offsets.filter { items.indices.contains($0) }.map { items[$0] }
        guard !moving.isEmpty else { return }
        let before = offsets.filter { $0 < destination }.count
        for i in offsets.sorted(by: >) where items.indices.contains(i) { items.remove(at: i) }
        let at = min(max(destination - before, 0), items.count)
        items.insert(contentsOf: moving, at: at)
    }

    func index(of id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    mutating func setState(_ id: UUID, _ state: BatchItem.State) {
        if let i = index(of: id) { items[i].state = state }
    }

    mutating func setOutput(_ id: UUID, _ url: URL?) {
        if let i = index(of: id) { items[i].output = url }
    }

    // MARK: Run state machine

    var hasPending: Bool { items.contains { $0.state == .pending } }
    var hasFailed: Bool { items.contains { if case .failed = $0.state { return true } else { return false } } }

    /// Start or resume. Failed items go back to pending (retry). False when there is nothing to do or it already runs.
    @discardableResult
    mutating func start() -> Bool {
        switch runState {
        case .running: return false
        case .pausing: runState = .running; return false   // resume before the pause took effect: the loop is still alive
        case .idle, .paused:
            for i in items.indices { if case .failed = items[i].state { items[i].state = .pending } }
            guard hasPending else { runState = .idle; return false }
            runState = .running
            return true
        }
    }

    /// Ask to stop after the current item.
    mutating func pause() {
        if runState == .running { runState = .pausing }
    }

    /// The runner asks for the next item. Returns nil (and settles the state) when paused or finished.
    mutating func beginNext() -> UUID? {
        if runState == .pausing { runState = hasPending ? .paused : .idle; return nil }
        guard runState == .running else { return nil }
        guard let i = items.firstIndex(where: { $0.state == .pending }) else { runState = .idle; return nil }
        items[i].state = .analysing(0)
        return items[i].id
    }

    // MARK: Progress

    /// Fraction of one item, with analysis taking about half of the work when an export follows.
    static func fraction(_ state: BatchItem.State, export: Bool) -> Double {
        let a = export ? 0.5 : 1.0
        switch state {
        case .pending: return 0
        case .analysing(let p): return min(max(p, 0), 1) * a * 0.9
        case .building: return a * 0.9
        case .exporting(let p): return a + min(max(p, 0), 1) * (1 - a)
        case .done, .failed: return 1
        }
    }

    func overallProgress(export: Bool) -> Double {
        guard !items.isEmpty else { return 0 }
        return items.map { Self.fraction($0.state, export: export) }.reduce(0, +) / Double(items.count)
    }

    // MARK: Output naming

    /// `<folder>/<source name>-reframed.<ext>`, with `-2`, `-3`… added when the name is already used by another item or exists on disk.
    static func outputURL(for source: URL, in folder: URL, ext: String, taken: Set<String> = [],
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = source.deletingPathExtension().lastPathComponent + "-reframed"
        var n = 1
        while true {
            let name = (n == 1 ? base : "\(base)-\(n)") + "." + ext
            let url = folder.appendingPathComponent(name)
            if !taken.contains(url.standardizedFileURL.path), !exists(url) { return url }
            n += 1
        }
    }

    /// Outputs already assigned to items.
    var takenOutputs: Set<String> { Set(items.compactMap { $0.output?.standardizedFileURL.path }) }
}
