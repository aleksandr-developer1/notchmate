import AppKit
import SwiftUI

struct NotesView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var obsidian: ObsidianService
    @EnvironmentObject var settings: Settings

    var body: some View {
        // Apple Notes by default; the Standard/Obsidian switcher appears only once a vault is connected.
        let source: NotesSource = obsidian.isConnected ? settings.notesSource : .apple
        VStack(spacing: 8) {
            if obsidian.isConnected {
                HStack(spacing: 4) {
                    ForEach(NotesSource.allCases) { sourceTab($0, selected: $0 == source) }
                    Spacer()
                }
            }
            if source == .obsidian {
                NotesPane(store: obsidian).id(NotesSource.obsidian)
            } else {
                NotesPane(store: env.appleNotes).id(NotesSource.apple)
            }
        }
    }

    private func sourceTab(_ s: NotesSource, selected: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { settings.notesSource = s }
        } label: {
            Label(s.title, systemImage: s == .apple ? "note.text" : "text.book.closed")
                .font(Theme.font(11, .semibold))
                .foregroundStyle(selected ? .white : Theme.secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(selected ? 0.14 : 0.0001)))
        }
        .buttonStyle(.plain)
    }
}

private struct NotesPane<Store: NotesStore>: View {
    @ObservedObject var store: Store
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var vm: NotchViewModel

    @State private var captureText = ""
    @State private var query = ""
    @State private var hits: [NoteSearchHit] = []
    @State private var selected: NoteItem?
    @State private var savedFlash = false
    @FocusState private var captureFocused: Bool
    @FocusState private var searchFocused: Bool

    private var isObsidian: Bool { store.source == .obsidian }
    private var tint: Color { isObsidian ? Theme.obsidian : .yellow }

    var body: some View {
        Group {
            if let message = store.unavailableMessage {
                UnavailableView(source: store.source, message: message)
            } else {
                VStack(spacing: 10) {
                    captureBar
                    HStack(alignment: .top, spacing: 10) {
                        listColumn.frame(width: 232)
                        NotePreview(store: store, note: selected ?? store.pinned.first ?? store.recent.first, tint: tint)
                    }
                }
                .onChange(of: captureFocused) { _, _ in vm.isTyping = captureFocused || searchFocused }
                .onChange(of: searchFocused) { _, _ in vm.isTyping = captureFocused || searchFocused }
                .onReceive(NotificationCenter.default.publisher(for: .notchMateFocusCapture)) { _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { captureFocused = true }
                }
                .task(id: query) {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled else { return }
                    hits = await store.search(query)
                }
            }
        }
        .onAppear { store.refresh(force: false) }
    }

    // MARK: Capture

    private var captureBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 22)

            TextField("", text: $captureText, prompt: Text("Записать мысль…").foregroundStyle(Theme.tertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.font(14))
                .foregroundStyle(.white)
                .lineLimit(1...3)
                .focused($captureFocused)
                .onSubmit(save)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.command) { createNote(); return .handled }
                    if press.modifiers.contains(.shift) { return .ignored }
                    save(); return .handled
                }

            if savedFlash {
                Label("Сохранено", systemImage: "checkmark.circle.fill")
                    .font(Theme.font(11, .semibold)).foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            } else {
                Text(settings.captureTarget == .daily ? "↩ в заметку дня · ⌘↩ новая" : "↩ во «Входящие» · ⌘↩ новая")
                    .font(Theme.font(10, .medium)).foregroundStyle(Theme.tertiary)
                    .opacity(captureText.isEmpty ? 0.8 : 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 40)
        .card(radius: 12, fill: Color.white.opacity(captureFocused ? 0.1 : 0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(captureFocused ? 0.6 : 0), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.2), value: captureFocused)
    }

    private func save() {
        guard store.capture(captureText) else { return }
        captureText = ""
        flash()
        NotificationCenter.default.post(name: .notchMateCaptureSaved, object: store.lastCaptureMessage)
    }

    private func createNote() {
        let lines = captureText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let title = lines.first.map(String.init), !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let body = lines.count > 1 ? String(lines[1]) : ""
        if let note = store.createNote(title: title, body: body) {
            captureText = ""
            selected = note
            flash()
            store.open(note)
        }
    }

    private func flash() {
        withAnimation(.spring(response: 0.3)) { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut) { savedFlash = false }
        }
    }

    // MARK: List

    private var listColumn: some View {
        VStack(spacing: 8) {
            GlassField(icon: "magnifyingglass", placeholder: "Поиск по \(store.notes.count) заметкам", text: $query, focus: $searchFocused) {
                if let first = hits.first { store.open(first.note) }
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        if !store.pinned.isEmpty {
                            sectionHeader("Закреплённые", icon: "pin.fill")
                            ForEach(store.pinned) { row($0, snippet: nil) }
                        }
                        sectionHeader("Недавние", icon: "clock")
                        ForEach(store.recent.filter { !store.isPinned($0) }) { row($0, snippet: nil) }
                    } else if hits.isEmpty {
                        VStack(spacing: 8) {
                            Text("Ничего не найдено").font(Theme.font(12)).foregroundStyle(Theme.secondary)
                            PillButton(title: "Создать «\(query)»", icon: "plus") {
                                if let n = store.createNote(title: query, body: "") { selected = n; query = "" }
                            }
                        }
                        .frame(maxWidth: .infinity).padding(.top, 20)
                    } else {
                        ForEach(hits) { row($0.note, snippet: $0.snippet) }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(Theme.font(10, .bold)).foregroundStyle(Theme.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
    }

    private func row(_ note: NoteItem, snippet: String?) -> some View {
        let isSelected = (selected ?? store.pinned.first ?? store.recent.first)?.id == note.id
        return HoverRow(selected: isSelected, radius: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: store.isPinned(note) ? "pin.fill" : "doc.text")
                        .font(.system(size: 10)).foregroundStyle(store.isPinned(note) ? tint : Theme.tertiary)
                        .frame(width: 12)
                    Text(note.title).font(Theme.font(12, .medium)).foregroundStyle(.white).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(note.modified, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                        .font(Theme.font(9)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                if let snippet {
                    Text(snippet).font(Theme.font(10)).foregroundStyle(Theme.secondary).lineLimit(2).padding(.leading, 18)
                } else if !note.folder.isEmpty {
                    Text(note.folder).font(Theme.font(10)).foregroundStyle(Theme.tertiary).lineLimit(1).padding(.leading, 18)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .onTapGesture(count: 2) { store.open(note) }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { selected = note } }
        .contextMenu {
            Button(isObsidian ? "Открыть в Obsidian" : "Открыть в Заметках") { store.open(note) }
            Button(store.isPinned(note) ? "Открепить" : "Закрепить") { store.togglePin(note) }
            if isObsidian {
                Button("Показать в Finder") { reveal(note) }
                Button("Копировать ссылку [[…]]") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("[[\(note.title)]]", forType: .string)
                }
            }
        }
    }

    private func reveal(_ note: NoteItem) {
        guard let url = note.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Preview

private struct NotePreview<Store: NotesStore>: View {
    @ObservedObject var store: Store
    let note: NoteItem?
    let tint: Color
    @State private var content = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let note {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(note.title).font(Theme.font(15, .bold)).foregroundStyle(.white).lineLimit(1)
                        if !note.folder.isEmpty {
                            Text(note.folder).font(Theme.font(10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                    }
                    Spacer()
                    IconButton(systemName: store.isPinned(note) ? "pin.fill" : "pin", size: 11, frame: 26,
                               tint: store.isPinned(note) ? tint : .white, help: "Закрепить") {
                        store.togglePin(note)
                    }
                    if let url = note.url {
                        IconButton(systemName: "folder", size: 11, frame: 26, help: "Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    PillButton(title: "Открыть", icon: "arrow.up.forward", tint: tint, prominent: true) { store.open(note) }
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

                Divider().overlay(Theme.stroke)

                ScrollView(.vertical, showsIndicators: false) {
                    MarkdownBody(markdown: content)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "text.book.closed").font(.system(size: 28)).foregroundStyle(Theme.tertiary)
                    Text("Выберите заметку").font(Theme.font(12)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 14)
        .onAppear { load() }
        .onChange(of: note) { _, _ in load() }
        .onChange(of: store.notes) { _, _ in load() }
    }

    private func load() {
        content = note.map { store.read($0) } ?? ""
    }
}

/// Lightweight Obsidian-flavoured markdown renderer (headings, lists, tasks, quotes, code, wikilinks).
struct MarkdownBody: View {
    let markdown: String

    private struct Line: Identifiable {
        enum Kind { case h1, h2, h3, bullet(Int), task(Bool, Int), quote, code, rule, text, blank }
        let id: Int
        let kind: Kind
        let text: String
    }

    var body: some View {
        let lines = parse()
        VStack(alignment: .leading, spacing: 3) {
            if lines.allSatisfy({ if case .blank = $0.kind { return true }; return false }) {
                Text("Пустая заметка").font(Theme.font(12)).foregroundStyle(Theme.tertiary)
            }
            ForEach(lines) { line in view(for: line) }
        }
    }

    @ViewBuilder private func view(for line: Line) -> some View {
        switch line.kind {
        case .h1: inline(line.text).font(Theme.font(17, .bold)).foregroundStyle(.white).padding(.top, 4)
        case .h2: inline(line.text).font(Theme.font(15, .bold)).foregroundStyle(.white).padding(.top, 3)
        case .h3: inline(line.text).font(Theme.font(13, .bold)).foregroundStyle(.white.opacity(0.9)).padding(.top, 2)
        case .bullet(let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle().fill(Theme.obsidian.opacity(0.8)).frame(width: 4, height: 4).offset(y: -2)
                inline(line.text).font(Theme.font(12)).foregroundStyle(.white.opacity(0.85))
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .task(let done, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12)).foregroundStyle(done ? Theme.obsidian : Theme.secondary)
                inline(line.text).font(Theme.font(12))
                    .foregroundStyle(done ? Theme.tertiary : .white.opacity(0.9))
                    .strikethrough(done, color: Theme.tertiary)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote:
            inline(line.text).font(Theme.font(12)).italic().foregroundStyle(Theme.secondary)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Capsule().fill(Theme.obsidian.opacity(0.6)).frame(width: 2) }
        case .code:
            Text(line.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
        case .rule: Divider().overlay(Theme.stroke).padding(.vertical, 4)
        case .text: inline(line.text).font(Theme.font(12)).foregroundStyle(.white.opacity(0.85))
        case .blank: Color.clear.frame(height: 4)
        }
    }

    private func inline(_ s: String) -> Text {
        // Wikilinks [[target|alias]] -> **alias**; embeds ![[x]] -> 📎 x; tags stay.
        var t = s.replacingOccurrences(of: "!\\[\\[([^\\]|]+)(\\|[^\\]]*)?\\]\\]", with: "📎 $1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[\\[([^\\]|]+)\\|([^\\]]+)\\]\\]", with: "**$2**", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[\\[([^\\]]+)\\]\\]", with: "**$1**", options: .regularExpression)
        t = t.replacingOccurrences(of: "==([^=]+)==", with: "**$1**", options: .regularExpression)
        if let attr = try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(t)
    }

    private func parse() -> [Line] {
        var out: [Line] = []
        var inCode = false
        var inFrontmatter = false
        let raw = markdown.components(separatedBy: "\n")
        for (i, rawLine) in raw.enumerated() {
            if i == 0 && rawLine.trimmingCharacters(in: .whitespaces) == "---" { inFrontmatter = true; continue }
            if inFrontmatter {
                if rawLine.trimmingCharacters(in: .whitespaces) == "---" { inFrontmatter = false }
                continue
            }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { out.append(Line(id: i, kind: .code, text: rawLine)); continue }
            let indent = (rawLine.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }) / 2
            if trimmed.isEmpty {
                if case .blank = out.last?.kind {} else { out.append(Line(id: i, kind: .blank, text: "")) }
            } else if trimmed.hasPrefix("### ") { out.append(Line(id: i, kind: .h3, text: String(trimmed.dropFirst(4)))) }
            else if trimmed.hasPrefix("## ") { out.append(Line(id: i, kind: .h2, text: String(trimmed.dropFirst(3)))) }
            else if trimmed.hasPrefix("# ") { out.append(Line(id: i, kind: .h1, text: String(trimmed.dropFirst(2)))) }
            else if trimmed.hasPrefix("- [ ] ") || trimmed == "- [ ]" { out.append(Line(id: i, kind: .task(false, indent), text: String(trimmed.dropFirst(6)))) }
            else if trimmed.lowercased().hasPrefix("- [x] ") { out.append(Line(id: i, kind: .task(true, indent), text: String(trimmed.dropFirst(6)))) }
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") { out.append(Line(id: i, kind: .bullet(indent), text: String(trimmed.dropFirst(2)))) }
            else if trimmed.hasPrefix(">") { out.append(Line(id: i, kind: .quote, text: trimmed.drop { $0 == ">" || $0 == " " }.description)) }
            else if trimmed == "---" || trimmed == "***" { out.append(Line(id: i, kind: .rule, text: "")) }
            else { out.append(Line(id: i, kind: .text, text: trimmed)) }
        }
        return Array(out.prefix(400))
    }
}

private struct UnavailableView: View {
    let source: NotesSource
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: source == .obsidian ? "text.book.closed.fill" : "note.text")
                .font(.system(size: 34)).foregroundStyle(source == .obsidian ? Theme.obsidian : .yellow)
            Text(message).font(Theme.font(15, .bold)).foregroundStyle(.white).multilineTextAlignment(.center)
            if source == .obsidian {
                Text("Откройте хранилище в Obsidian или выберите папку в настройках")
                    .font(Theme.font(12)).foregroundStyle(Theme.secondary)
                PillButton(title: "Выбрать папку…", icon: "folder", tint: Theme.obsidian, prominent: true) {
                    NotificationCenter.default.post(name: .notchMateOpenSettings, object: nil)
                }
            } else {
                Text("NotchMate нужен доступ к приложению «Заметки»")
                    .font(Theme.font(12)).foregroundStyle(Theme.secondary)
                PillButton(title: "Открыть настройки", icon: "gearshape", tint: .yellow, prominent: true) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 16)
    }
}
