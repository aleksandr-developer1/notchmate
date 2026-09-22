import AppKit
import Foundation

/// Apple Notes via JXA (`osascript -l JavaScript`); macOS asks for Automation access to Notes once.
@MainActor
final class AppleNotesService: NotesStore {
    @Published private(set) var notes: [NoteItem] = []
    @Published private(set) var unavailableMessage: String?
    @Published private(set) var isLoaded = false
    @Published var lastCaptureMessage: String?

    let source = NotesSource.apple

    private let settings = Settings.shared
    private var texts: [String: String] = [:]
    private var lastScan = Date.distantPast
    private var loading: Task<Void, Never>?

    var recent: [NoteItem] { Array(notes.prefix(12)) }

    var pinned: [NoteItem] {
        settings.pinnedAppleNotes.compactMap { id in notes.first { $0.id == id } }
    }

    func isPinned(_ note: NoteItem) -> Bool { settings.pinnedAppleNotes.contains(note.id) }

    func togglePin(_ note: NoteItem) {
        if let i = settings.pinnedAppleNotes.firstIndex(of: note.id) {
            settings.pinnedAppleNotes.remove(at: i)
        } else {
            settings.pinnedAppleNotes.append(note.id)
        }
        objectWillChange.send()
    }

    // MARK: Loading

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastScan) > 15 else { return }
        lastScan = Date()
        _ = load()
    }

    @discardableResult
    private func load() -> Task<Void, Never> {
        if let loading { return loading }
        let task = Task {
            let result = await Task.detached(priority: .utility) { Self.jxa(Self.listScript) }.value
            switch result {
            case .success(let json):
                let raw = (try? JSONDecoder().decode([RawNote].self, from: Data(json.utf8))) ?? []
                var seen = Set<String>()
                let unique = raw.filter { seen.insert($0.id).inserted }
                notes = unique
                    .map { NoteItem(id: $0.id, title: $0.title, folder: $0.folder, modified: Date(timeIntervalSince1970: $0.modified)) }
                    .sorted { $0.modified > $1.modified }
                texts = Dictionary(unique.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
                unavailableMessage = nil
            case .failure(let error):
                unavailableMessage = error.message
            }
            isLoaded = true
            loading = nil
        }
        loading = task
        return task
    }

    private struct RawNote: Decodable {
        let id, title, folder, text: String
        let modified: Double
    }

    // MARK: Search / reading

    func search(_ query: String) async -> [NoteSearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        if !isLoaded { await load().value }
        let snapshot = notes, texts = texts
        return await Task.detached(priority: .userInitiated) {
            var hits: [NoteSearchHit] = []
            for note in snapshot {
                let title = note.title.lowercased()
                var score = 0
                if title == q { score = 1000 }
                else if title.hasPrefix(q) { score = 800 }
                else if title.contains(q) { score = 600 }
                else if ObsidianService.fuzzy(q, in: title) { score = 400 }
                else if note.folder.lowercased().contains(q) { score = 300 }
                var snippet: String?
                let text = texts[note.id] ?? ""
                if let range = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                    if score == 0 { score = 200 }
                    snippet = ObsidianService.snippet(text, around: range)
                }
                if score > 0 { hits.append(NoteSearchHit(note: note, snippet: snippet, score: score)) }
            }
            hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.note.modified > $1.note.modified }
            return Array(hits.prefix(40))
        }.value
    }

    func read(_ note: NoteItem) -> String {
        let text = texts[note.id] ?? ""
        // Plaintext repeats the title as its first line; the preview header already shows it.
        guard let first = text.firstIndex(of: "\n"), text[..<first].trimmingCharacters(in: .whitespaces) == note.title else { return text }
        return String(text[text.index(after: first)...])
    }

    // MARK: Writing

    /// Appends to today's note ("2026-09-16") or to «Входящие», creating it when missing.
    @discardableResult
    func capture(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let title: String
        switch settings.captureTarget {
        case .daily:
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            title = df.string(from: Date())
        case .inbox:
            title = (settings.inboxPath as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        let stamp = settings.captureTimestamp ? "\(fmt.string(from: Date())) " : ""
        let lines = trimmed.components(separatedBy: "\n")
        let html = lines.enumerated()
            .map { "<div>\($0.offset == 0 ? "• " + stamp : "")\(Self.escape($0.element))</div>" }
            .joined()

        let result: Result<String, NotesError>
        if let existing = notes.first(where: { $0.title == title }) {
            result = Self.jxa(Self.appendScript, [existing.id, html])
        } else {
            result = Self.jxa(Self.createScript, ["<div><h1>\(Self.escape(title))</h1></div>" + html])
        }
        switch result {
        case .success:
            lastCaptureMessage = String(localized: "Сохранено в «\(title)»")
            refresh(force: true)
            return true
        case .failure(let error):
            lastCaptureMessage = String(localized: "Не удалось сохранить: \(error.message)")
            return false
        }
    }

    func createNote(title: String, body: String = "") -> NoteItem? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let html = "<div><h1>\(Self.escape(clean))</h1></div>"
            + body.components(separatedBy: "\n").map { "<div>\($0.isEmpty ? "<br>" : Self.escape($0))</div>" }.joined()
        guard case .success(let json) = Self.jxa(Self.createScript, [html]),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String],
              let id = obj["id"] else { return nil }
        let note = NoteItem(id: id, title: clean, folder: obj["folder"] ?? "", modified: Date())
        notes.insert(note, at: 0)
        texts[id] = clean + "\n" + body
        refresh(force: true)
        return note
    }

    func open(_ note: NoteItem) {
        let id = note.id
        Task.detached(priority: .userInitiated) { _ = Self.jxa(Self.showScript, [id]) }
    }

    // MARK: JXA

    struct NotesError: Error {
        let message: String
    }

    nonisolated private static let listScript = """
    function run() {
      const N = Application('Notes'); const out = [];
      N.folders().forEach(f => {
        const name = f.name(), ids = f.notes.id(), titles = f.notes.name(),
              dates = f.notes.modificationDate(), texts = f.notes.plaintext();
        for (let i = 0; i < ids.length; i++)
          out.push({id: ids[i], title: titles[i], folder: name, modified: dates[i].getTime() / 1000, text: texts[i]});
      });
      return JSON.stringify(out);
    }
    """

    nonisolated private static let appendScript = """
    function run(argv) {
      const n = Application('Notes').notes.byId(argv[0]);
      n.body = n.body() + argv[1];
      return 'ok';
    }
    """

    nonisolated private static let createScript = """
    function run(argv) {
      const N = Application('Notes');
      const folder = N.defaultAccount().defaultFolder();
      const n = N.Note({body: argv[0]});
      folder.notes.push(n);
      return JSON.stringify({id: n.id(), folder: folder.name()});
    }
    """

    nonisolated private static let showScript = """
    function run(argv) {
      const N = Application('Notes');
      N.show(N.notes.byId(argv[0]));
      N.activate();
    }
    """

    nonisolated private static func jxa(_ script: String, _ args: [String] = []) -> Result<String, NotesError> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-l", "JavaScript", "-e", script] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(NotesError(message: error.localizedDescription)) }
        // Drain stderr in parallel: reading the pipes one after another deadlocks once
        // the unread one fills its 64 KB buffer.
        nonisolated(unsafe) var errData = Data()
        let errRead = DispatchGroup()
        errRead.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readAll(); errRead.leave() }
        let data = out.fileHandleForReading.readAll()
        errRead.wait()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(decoding: errData, as: UTF8.self)
            if text.contains("-1743") || text.contains("Not authorized") {
                return .failure(NotesError(message: String(localized: "Нет доступа к «Заметкам» — разрешите в Автоматизации")))
            }
            return .failure(NotesError(message: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    nonisolated private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
