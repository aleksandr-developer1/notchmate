import AppKit
import Foundation

struct VaultInfo: Identifiable, Hashable {
    let path: String
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct NoteItem: Identifiable, Hashable {
    let id: String
    let title: String
    let folder: String
    let modified: Date
    /// File on disk (Obsidian); nil for Apple Notes.
    let url: URL?
    let relativePath: String   // "Проекты/Идея.md"

    /// Obsidian note backed by a markdown file.
    init(url: URL, relativePath: String, modified: Date) {
        self.id = relativePath
        self.url = url
        self.relativePath = relativePath
        self.modified = modified
        self.title = ((relativePath as NSString).lastPathComponent as NSString).deletingPathExtension
        self.folder = (relativePath as NSString).deletingLastPathComponent
    }

    /// Apple Notes note, identified by its Core Data id.
    init(id: String, title: String, folder: String, modified: Date) {
        self.id = id
        self.url = nil
        self.title = title
        self.folder = folder
        self.modified = modified
        self.relativePath = folder.isEmpty ? title : "\(folder)/\(title)"
    }
}

struct NoteSearchHit: Identifiable, Hashable {
    let note: NoteItem
    let snippet: String?
    let score: Int
    var id: String { note.id }
}

enum NotesSource: String, CaseIterable, Identifiable {
    case apple, obsidian
    var id: String { rawValue }
    var title: String { self == .apple ? "Стандартные" : "Obsidian" }
}

/// What the notes tab needs from a notes backend (Apple Notes or an Obsidian vault).
@MainActor
protocol NotesStore: ObservableObject {
    var source: NotesSource { get }
    var notes: [NoteItem] { get }
    var recent: [NoteItem] { get }
    var pinned: [NoteItem] { get }
    var lastCaptureMessage: String? { get }
    /// Non-nil when the store can't be used (no vault, no Automation access…).
    var unavailableMessage: String? { get }
    func isPinned(_ note: NoteItem) -> Bool
    func togglePin(_ note: NoteItem)
    func refresh(force: Bool)
    func search(_ query: String) async -> [NoteSearchHit]
    func read(_ note: NoteItem) -> String
    func capture(_ text: String) -> Bool
    func createNote(title: String, body: String) -> NoteItem?
    func open(_ note: NoteItem)
}

@MainActor
final class ObsidianService: NotesStore {
    @Published private(set) var vaults: [VaultInfo] = []
    @Published private(set) var notes: [NoteItem] = []
    @Published private(set) var isIndexing = false
    @Published var lastCaptureMessage: String?

    private let settings = Settings.shared
    private var contentCache: [String: (Date, String)] = [:]
    private var lastScan = Date.distantPast

    let source = NotesSource.obsidian

    var vault: VaultInfo? {
        if !settings.vaultPath.isEmpty { return VaultInfo(path: settings.vaultPath) }
        return vaults.first
    }

    var isObsidianInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
    }

    /// Obsidian counts as connected once a vault is chosen or detected.
    var isConnected: Bool { vault != nil }

    var unavailableMessage: String? { vault == nil ? "Хранилище Obsidian не найдено" : nil }

    func start() {
        loadVaults()
        refresh(force: true)
    }

    func loadVaults() {
        let cfg = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: cfg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dict = json["vaults"] as? [String: [String: Any]] else { return }
        let sorted = dict.values.sorted {
            let o0 = $0["open"] as? Bool ?? false, o1 = $1["open"] as? Bool ?? false
            if o0 != o1 { return o0 }
            return ($0["ts"] as? Double ?? 0) > ($1["ts"] as? Double ?? 0)
        }
        vaults = sorted.compactMap { $0["path"] as? String }
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map(VaultInfo.init(path:))
    }

    /// Rescans the vault in the background. Cheap enough to call on every open.
    func refresh(force: Bool = false) {
        guard let vault else { notes = []; return }
        guard force || Date().timeIntervalSince(lastScan) > 3 else { return }
        lastScan = Date()
        isIndexing = true
        let root = URL(fileURLWithPath: vault.path)
        Task.detached(priority: .utility) {
            let items = Self.scan(root: root)
            await MainActor.run {
                self.notes = items
                self.isIndexing = false
            }
        }
    }

    nonisolated private static func scan(root: URL) -> [NoteItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let rootPath = root.standardizedFileURL.path
        var out: [NoteItem] = []
        for case let url as URL in en {
            if url.lastPathComponent == ".trash" || url.lastPathComponent == "node_modules" {
                en.skipDescendants(); continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let vals = try? url.resourceValues(forKeys: Set(keys))
            let full = url.standardizedFileURL.path
            var rel = String(full.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            out.append(NoteItem(url: url, relativePath: rel, modified: vals?.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    var recent: [NoteItem] { Array(notes.prefix(12)) }

    private var pinnedPaths: [String] {
        get { settings.pinnedNotes }
        set { settings.pinnedNotes = newValue }
    }

    var pinned: [NoteItem] {
        pinnedPaths.compactMap { rel in notes.first { $0.relativePath == rel } }
    }

    func isPinned(_ note: NoteItem) -> Bool { pinnedPaths.contains(note.relativePath) }

    func togglePin(_ note: NoteItem) {
        if let i = pinnedPaths.firstIndex(of: note.relativePath) {
            pinnedPaths.remove(at: i)
        } else {
            pinnedPaths.append(note.relativePath)
        }
        objectWillChange.send()
    }

    // MARK: Search

    func search(_ query: String) async -> [NoteSearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let snapshot = notes
        let cache = contentCache
        let (hits, newCache) = await Task.detached(priority: .userInitiated) { () -> ([NoteSearchHit], [String: (Date, String)]) in
            var cache = cache
            var hits: [NoteSearchHit] = []
            for note in snapshot {
                let title = note.title.lowercased()
                var score = 0
                if title == q { score = 1000 }
                else if title.hasPrefix(q) { score = 800 }
                else if title.contains(q) { score = 600 }
                else if Self.fuzzy(q, in: title) { score = 400 }
                else if note.relativePath.lowercased().contains(q) { score = 300 }

                var snippet: String?
                let text: String
                if let (date, cached) = cache[note.relativePath], date == note.modified {
                    text = cached
                } else {
                    text = note.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
                    cache[note.relativePath] = (note.modified, text)
                }
                if let range = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                    if score == 0 { score = 200 }
                    snippet = Self.snippet(text, around: range)
                }
                if score > 0 { hits.append(NoteSearchHit(note: note, snippet: snippet, score: score)) }
            }
            hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.note.modified > $1.note.modified }
            return (Array(hits.prefix(40)), cache)
        }.value
        contentCache = newCache
        return hits
    }

    nonisolated static func fuzzy(_ q: String, in s: String) -> Bool {
        var it = s.makeIterator()
        outer: for ch in q where ch != " " {
            while let c = it.next() { if c == ch { continue outer } }
            return false
        }
        return true
    }

    nonisolated static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start != text.startIndex { s = "…" + s }
        if end != text.endIndex { s += "…" }
        return s
    }

    // MARK: Reading / editing

    func read(_ note: NoteItem) -> String {
        note.url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    // MARK: Capture

    @discardableResult
    func capture(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let vault else { return false }
        let root = URL(fileURLWithPath: vault.path)
        let rel: String
        switch settings.captureTarget {
        case .daily: rel = dailyNoteRelativePath(vault: root)
        case .inbox: rel = settings.inboxPath.hasSuffix(".md") ? settings.inboxPath : settings.inboxPath + ".md"
        }
        let url = root.appendingPathComponent(rel)
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        let prefix = "- "
        let stamp = settings.captureTimestamp ? "\(fmt.string(from: Date())) " : ""
        let body = trimmed.components(separatedBy: "\n").enumerated()
            .map { $0.offset == 0 ? prefix + stamp + $0.element : "  " + $0.element }
            .joined(separator: "\n")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
            try (existing + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            lastCaptureMessage = "Сохранено в «\((rel as NSString).deletingPathExtension)»"
            refresh(force: true)
            return true
        } catch {
            lastCaptureMessage = "Не удалось сохранить: \(error.localizedDescription)"
            return false
        }
    }

    /// Creates a new note; returns it.
    func createNote(title: String, body: String = "") -> NoteItem? {
        guard let vault else { return nil }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty else { return nil }
        let root = URL(fileURLWithPath: vault.path)
        var folder = newNoteFolder(vault: root)
        if !folder.isEmpty { folder += "/" }
        var rel = "\(folder)\(clean).md"
        var i = 2
        while FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) {
            rel = "\(folder)\(clean) \(i).md"; i += 1
        }
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        refresh(force: true)
        return NoteItem(url: url, relativePath: rel, modified: Date())
    }

    func openDailyNote() {
        guard let vault else { return }
        let root = URL(fileURLWithPath: vault.path)
        let rel = dailyNoteRelativePath(vault: root)
        let url = root.appendingPathComponent(rel)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        open(relativePath: rel)
    }

    private func dailyNoteRelativePath(vault root: URL) -> String {
        let cfgURL = root.appendingPathComponent(".obsidian/daily-notes.json")
        var folder = "", format = "YYYY-MM-DD"
        if let data = try? Data(contentsOf: cfgURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            folder = (json["folder"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let f = json["format"] as? String, !f.isEmpty { format = f }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = Self.momentToICU(format)
        let name = df.string(from: Date())
        return folder.isEmpty ? "\(name).md" : "\(folder)/\(name).md"
    }

    private func newNoteFolder(vault root: URL) -> String {
        let cfgURL = root.appendingPathComponent(".obsidian/app.json")
        guard let data = try? Data(contentsOf: cfgURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["newFileLocation"] as? String) == "folder" else { return "" }
        return (json["newFileFolderPath"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Converts the common subset of moment.js tokens to ICU date format.
    static func momentToICU(_ f: String) -> String {
        var s = f
        // Protect bracketed literals: [W] -> 'W'
        s = s.replacingOccurrences(of: "\\[([^\\]]*)\\]", with: "'$1'", options: .regularExpression)
        let map: [(String, String)] = [("YYYY", "yyyy"), ("YY", "yy"), ("dddd", "EEEE"), ("ddd", "EEE"),
                                       ("DDDD", "DDD"), ("DD", "dd"), ("Do", "d"), ("D", "d")]
        for (a, b) in map { s = s.replacingOccurrences(of: a, with: b) }
        return s
    }

    // MARK: Open in Obsidian

    func open(_ note: NoteItem) { open(relativePath: note.relativePath) }

    func open(relativePath rel: String) {
        guard let vault else { return }
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "vault", value: vault.name), URLQueryItem(name: "file", value: rel)]
        if let url = comps.url {
            NSWorkspace.shared.open(url)
        }
    }

    func openSearchInObsidian(_ query: String) {
        guard let vault else { return }
        var comps = URLComponents()
        comps.scheme = "obsidian"; comps.host = "search"
        comps.queryItems = [URLQueryItem(name: "vault", value: vault.name), URLQueryItem(name: "query", value: query)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    func reveal(_ note: NoteItem) {
        guard let url = note.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
