import AppKit
import Combine
import SwiftUI

/// Meeting assistant: listens to the call as it goes and quietly suggests what to ask, what to say
/// and what the code already has. Audio and speech recognition stay on the Mac; only the recent
/// transcript and short code excerpts go to the AI provider the user picked.
@MainActor
final class MeetingCopilot: ObservableObject {
    struct Hint: Identifiable, Equatable {
        let id = UUID()
        let date = Date()
        let question: String?
        var text = ""
        var isStreaming = true
        var isError = false

        enum Kind { case option, ask, say, code, risk, plain }
        struct Line: Identifiable, Equatable {
            let id: Int
            let kind: Kind
            let text: String
        }

        var lines: [Line] {
            text.split(separator: "\n").enumerated().compactMap { i, raw in
                let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
                guard !line.isEmpty, line != "—" else { return nil }
                for (prefix, kind) in [("ВАРИАНТ:", Kind.option), ("СПРОСИТЬ:", .ask), ("СКАЗАТЬ:", .say), ("КОД:", .code), ("РИСК:", .risk)] {
                    if line.uppercased().hasPrefix(prefix) {
                        return Line(id: i, kind: kind, text: String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
                    }
                }
                return Line(id: i, kind: .plain, text: line)
            }
        }

        var isEmptyAnswer: Bool { !isStreaming && !isError && lines.isEmpty }
    }

    private struct Segment {
        let started: Date
        var text: String
    }

    @Published private(set) var isActive = false
    @Published private(set) var isListening = false
    @Published private(set) var isThinking = false
    @Published private(set) var hints: [Hint] = []
    @Published private(set) var lastError: String?
    @Published private(set) var repoRoot: String?
    @Published private(set) var transcriptTail = ""
    @Published var draft = ""

    private weak var env: AppEnvironment?
    private let settings = Settings.shared
    private var live: LiveTranscriber?
    private var segments: [String: Segment] = [:]
    private var order: [String] = []
    private var lastChange = Date.distantPast
    private var lastHint = Date.distantPast
    private var charsAtLastHint = 0
    private var hintTask: Task<Void, Never>?
    private var ticker: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var repoChosenByUser = false
    private var overview: (root: String, text: String)?
    /// Code search terms the model derived from the conversation, refreshed in the background.
    private var searchTerms: [String] = []
    private var termsAt = Date.distantPast
    private var termsChars = 0
    private var termsRunning = false
    /// Code excerpts for the latest search terms, prepared ahead so a hint doesn't wait for git.
    private var codeCache: (root: String, terms: [String], text: String)?
    private var codeRunning = false

    var onVisibilityChanged: ((Bool) -> Void)?

    private static let resumeKey = "meetingCopilotActiveAt"

    func start(env: AppEnvironment) {
        self.env = env
        // NotchMate restarted mid-call (update, crash): bring the assistant back on its own.
        if let at = UserDefaults.standard.object(forKey: Self.resumeKey) as? Date, Date().timeIntervalSince(at) < 15 * 60 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MeetingLog.shared.write("resume_after_restart", ["was_active_at": at.description])
                self?.activate()
            }
        }
        // The call ended — stop listening, keep the hints on screen until closed.
        env.calls.$stage.removeDuplicates().sink { [weak self] stage in
            guard let self, self.isListening, stage != .recording else { return }
            self.stopListening()
        }.store(in: &cancellables)
    }

    // MARK: On / off

    /// The button: turns the mode on, or asks for a hint right away when it's already on.
    func toggleOrHint() {
        if isActive { hintNow() } else { activate() }
    }

    func activate() {
        guard let env else { return }
        isActive = true
        lastError = nil
        onVisibilityChanged?(true)
        UserDefaults.standard.set(Date(), forKey: Self.resumeKey)
        if !repoChosenByUser { repoRoot = env.git.status?.root ?? env.git.recent.first }
        refreshModels()
        MeetingLog.shared.begin()
        MeetingLog.shared.write("activate", ["repo": repoRoot ?? "", "locale": settings.callsLocale, "provider": env.ai.provider.rawValue,
                       "model": settings.meetingModel, "auto": settings.meetingAutoHints, "interval": settings.meetingHintInterval,
                       "call_stage": "\(env.calls.stage)", "mic_apps": env.calls.micApps, "capture_mic": settings.callsCaptureMic])
        prepareOverview()
        Task {
            guard await LiveTranscriber.authorize() else {
                MeetingLog.shared.write("error", ["where": "authorize"])
                lastError = String(localized: "Нет разрешения на распознавание речи — Системные настройки → Конфиденциальность → Распознавание речи")
                return
            }
            if env.calls.stage == .idle { await env.calls.beginRecording() }
            guard env.calls.stage == .recording else {
                MeetingLog.shared.write("error", ["where": "recording", "message": env.calls.lastError ?? "not recording"])
                lastError = env.calls.lastError ?? String(localized: "Созвон сейчас не записывается — помощнику нечего слушать")
                return
            }
            startListening()
        }
    }

    func close() {
        MeetingLog.shared.write("close", ["hints": hints.count, "segments": order.count, "chars": totalChars])
        UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        stopListening()
        hintTask?.cancel()
        env?.ai.cancelQuick()
        isThinking = false
        isActive = false
        onVisibilityChanged?(false)
    }

    func clear() {
        MeetingLog.shared.write("clear", ["hints": hints.count])
        hints.removeAll()
    }

    private func startListening() {
        guard !isListening, let env else { return }
        let live = LiveTranscriber(locale: settings.callsLocale, onUpdate: { [weak self] segment, text, _ in
            Task { @MainActor in self?.update(segment: segment, text: text) }
        }, onError: { [weak self] message in
            MeetingLog.shared.write("error", ["where": "live", "message": message])
            Task { @MainActor in self?.lastError = message }
        })
        guard let live else { MeetingLog.shared.write("error", ["where": "live_init"]); return }
        MeetingLog.shared.write("listening_start")
        self.live = live
        env.calls.tap.set { buffer, isMic in live.append(buffer, isMic: isMic) }
        isListening = true
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopListening() {
        if isListening { MeetingLog.shared.write("listening_stop", ["call_stage": "\(env?.calls.stage ?? .idle)"]) }
        env?.calls.tap.set(nil)
        live?.stop()
        live = nil
        ticker?.invalidate()
        ticker = nil
        isListening = false
    }

    // MARK: Fast models

    struct FastModel: Identifiable, Equatable {
        let provider: AIProvider
        let model: String
        let title: String
        var available: Bool
        var note: String
        var id: String { "\(provider.rawValue)|\(model)" }
    }

    @Published private(set) var fastModels: [FastModel] = []

    /// Small models only: a hint that comes after the moment has passed is useless.
    static func isFastName(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["haiku", "mini", "nano", "flash", "lite", "spark", "luna", "fast", "turbo", "instant", "8b", "7b", "4b", "3b"].contains { n.contains($0) }
    }

    func refreshModels() {
        guard let env else { return }
        let ai = env.ai
        var list: [FastModel] = [
            FastModel(provider: .anthropicKey, model: "claude-haiku-4-5", title: "Anthropic API · Claude Haiku 4.5",
                      available: ai.isReady(.anthropicKey), note: String(localized: "нужен ключ Anthropic")),
            FastModel(provider: .claude, model: "haiku", title: String(localized: "Claude (аккаунт) · Haiku"),
                      available: ai.isReady(.claude), note: String(localized: "войдите в Claude")),
        ]
        for id in ai.codexModelIDs where Self.isFastName(id) {
            list.append(FastModel(provider: .chatgpt, model: id, title: "ChatGPT · \(id)", available: ai.isReady(.chatgpt), note: String(localized: "войдите в ChatGPT")))
        }
        // Keep the chosen one in the list even before remote lists arrive.
        let chosen = settings.meetingModel
        if !chosen.isEmpty, !list.contains(where: { $0.id == chosen }), let bar = chosen.firstIndex(of: "|"),
           let provider = AIProvider(rawValue: String(chosen[..<bar])) {
            let model = String(chosen[chosen.index(after: bar)...])
            list.append(FastModel(provider: provider, model: model, title: "\(provider.title) · \(model)", available: ai.isReady(provider), note: ""))
        }
        fastModels = list
        Task { await loadRemoteModels() }
    }

    private func loadRemoteModels() async {
        guard let env else { return }
        var extra: [FastModel] = []
        if env.ai.isReady(.openaiKey), let key = Keychain.get(OpenAIKeyBackend.account),
           let ids = try? await OpenAIKeyBackend.models(key: key) {
            extra += ids.filter(Self.isFastName).map { FastModel(provider: .openaiKey, model: $0, title: "OpenAI API · \($0)", available: true, note: "") }
        }
        if env.ai.isReady(.customOpenAI), let ids = try? await CustomOpenAIBackend.models(baseURL: settings.aiCustomBaseURL, key: Keychain.get(CustomOpenAIBackend.account) ?? "") {
            extra += ids.filter(Self.isFastName).map { FastModel(provider: .customOpenAI, model: $0, title: String(localized: "Своя ИИ · \($0)"), available: true, note: "") }
        }
        for m in extra where !fastModels.contains(where: { $0.id == m.id }) { fastModels.append(m) }
        MeetingLog.shared.write("models", ["available": fastModels.filter(\.available).map(\.id), "chosen": settings.meetingModel])
    }

    /// The chosen model, or the fastest available (API keys first — no process to start).
    var currentModel: FastModel? {
        if let chosen = fastModels.first(where: { $0.id == settings.meetingModel && $0.available }) { return chosen }
        return fastModels.first { $0.available }
    }

    func chooseModel(_ id: String) {
        settings.meetingModel = id
        MeetingLog.shared.write("model_chosen", ["model": id])
        objectWillChange.send()
    }

    // MARK: Transcript

    private func update(segment: String, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if segments[segment] == nil {
            segments[segment] = Segment(started: Date(), text: clean)
            order.append(segment)
        } else if segments[segment]?.text != clean {
            segments[segment]?.text = clean
        } else {
            return
        }
        lastChange = Date()
        MeetingLog.shared.write("transcript", ["segment": segment, "text": clean])
        transcriptTail = String(transcript(limit: 220).suffix(220))
    }

    /// Recent conversation with speakers, oldest first.
    private func transcript(limit: Int) -> String {
        let ordered = order.compactMap { segments[$0] }.sorted { $0.started < $1.started }
        var lines: [String] = []
        var total = 0
        for s in ordered.reversed() {
            let line = "— " + s.text
            total += line.count
            lines.append(line)
            if total > limit { break }
        }
        return String(lines.reversed().joined(separator: "\n").suffix(limit))
    }

    private var totalChars: Int { segments.values.reduce(0) { $0 + $1.text.count } }

    // MARK: When to hint

    private func tick() {
        // Fresh mark for resuming after a restart, as long as the assistant is listening.
        if Int(Date().timeIntervalSince1970) % 30 == 0 { UserDefaults.standard.set(Date(), forKey: Self.resumeKey) }
        guard settings.meetingAutoHints, !isThinking else { return }
        let fresh = totalChars - charsAtLastHint
        let pause = Date().timeIntervalSince(lastChange)
        let sinceHint = Date().timeIntervalSince(lastHint)
        // Someone just asked something — answer fast.
        let latest = order.last.flatMap { segments[$0] }?.text
        let asked = latest?.hasSuffix("?") == true && fresh >= 20 && pause >= 0.8 && sinceHint >= 5
        let enough = fresh >= 100 && pause >= 1.5 && sinceHint >= Double(settings.meetingHintInterval)
        refreshSearchTermsIfNeeded()
        if asked || enough {
            MeetingLog.shared.write("auto_trigger", ["reason": asked ? "question" : "pause", "fresh_chars": fresh,
                                                     "pause_s": pause, "since_hint_s": sinceHint])
            requestHint(question: nil)
        }
    }

    private func refreshSearchTermsIfNeeded() {
        guard let env, repoRoot != nil, !termsRunning, let model = currentModel,
              totalChars - termsChars >= 250, Date().timeIntervalSince(termsAt) >= 25 else { return }
        termsRunning = true
        termsAt = Date()
        termsChars = totalChars
        let conversation = transcript(limit: 2500)
        let prompt = """
        Фрагмент рабочего разговора (распознавание речи, возможны ошибки). Выпиши через запятую до 8 слов для поиска по исходному коду: \
        как обсуждаемые сущности и действия обычно называются в коде — английские идентификаторы или их части, \
        аббревиатуры латиницей, нижний регистр. Самые важные первыми. Только список, без пояснений.

        \(conversation)
        """
        let started = Date()
        Task { [weak self] in
            let box = TextBox()
            do {
                try await env.ai.quick(prompt: prompt, system: "Отвечай только списком слов через запятую.",
                                       provider: model.provider, model: model.model, aux: true) { d in
                    Task { @MainActor in box.text += d }
                }
                await Task.yield()
            } catch {
                MeetingLog.shared.write("terms_error", ["message": error.localizedDescription])
            }
            guard let self else { return }
            let terms = box.text.lowercased().components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                .map { $0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "`'\".-"))) }
                .filter { $0.range(of: "^[a-z0-9_]{2,30}$", options: .regularExpression) != nil }
            if !terms.isEmpty { self.searchTerms = Array(terms.prefix(8)) }
            self.refreshCodeCache()
            self.termsRunning = false
            MeetingLog.shared.write("search_terms", ["terms": self.searchTerms, "raw": box.text, "ms": Int(Date().timeIntervalSince(started) * 1000)])
        }
    }

    private func refreshCodeCache() {
        guard let root = repoRoot, !codeRunning else { return }
        let terms = CodeContext.keywords(String(transcript(limit: 900)), extra: searchTerms)
        guard !terms.isEmpty, codeCache?.root != root || codeCache?.terms != terms else { return }
        codeRunning = true
        let text = String(transcript(limit: 900))
        let extra = searchTerms
        Task {
            let started = Date()
            let relevant = await Task.detached { CodeContext.relevant(root: root, text: text, extra: extra) }.value
            self.codeRunning = false
            guard self.repoRoot == root else { return }
            self.codeCache = (root, terms, relevant)
            MeetingLog.shared.write("code_cache", ["terms": terms, "chars": relevant.count, "ms": Int(Date().timeIntervalSince(started) * 1000)])
        }
    }

    func hintNow() {
        MeetingLog.shared.write("manual_trigger")
        requestHint(question: nil)
    }

    func ask() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        draft = ""
        MeetingLog.shared.write("ask", ["question": q])
        requestHint(question: q)
    }

    func chooseRepo(_ root: String?) {
        repoChosenByUser = true
        MeetingLog.shared.write("repo_chosen", ["repo": root ?? ""])
        repoRoot = root
        overview = nil
        codeCache = nil
        prepareOverview()
    }

    private func requestHint(question: String?) {
        guard let env else { return }
        hintTask?.cancel()
        env.ai.cancelQuick()
        lastHint = Date()
        charsAtLastHint = totalChars
        let conversation = transcript(limit: 3500)
        guard question != nil || conversation.count > 20 else {
            MeetingLog.shared.write("hint_skipped", ["reason": "empty transcript", "chars": conversation.count])
            lastError = String(localized: "Пока нечего подсказать — разговор ещё не расшифрован")
            return
        }
        lastError = nil
        // A running hint the new one replaces is dropped if it had nothing yet.
        if let first = hints.first, first.isStreaming {
            if first.text.isEmpty { hints.removeFirst() } else { hints[0].isStreaming = false }
        }
        hints.insert(Hint(question: question), at: 0)
        if hints.count > 12 { hints.removeLast(hints.count - 12) }
        let id = hints[0].id
        isThinking = true

        let root = repoRoot
        let previous = hints.dropFirst().prefix(6).map(\.text).filter { !$0.isEmpty }
        let title = env.calendar.events.first { $0.isNow }?.title
        let cachedOverview = overview?.root == root ? overview?.text : nil
        guard let model = currentModel else {
            hints.removeFirst()
            isThinking = false
            lastError = String(localized: "Нет доступной быстрой модели — добавьте ключ Anthropic/OpenAI или войдите в Claude/ChatGPT в настройках ИИ")
            MeetingLog.shared.write("hint_skipped", ["reason": "no fast model"])
            return
        }
        let role = settings.meetingRole.isEmpty ? String(localized: "специалист по обсуждаемой теме") : settings.meetingRole

        let requested = Date()
        let hintID = id.uuidString
        hintTask = Task { [weak self] in
            var overviewText = ""
            var relevantText = ""
            if let root {
                if let cachedOverview {
                    overviewText = cachedOverview
                } else {
                    overviewText = await Task.detached { CodeContext.overview(root: root) }.value
                    self?.overview = (root, overviewText)
                }
                if let cache = self?.codeCache, cache.root == root {
                    relevantText = cache.text
                } else {
                    let searchText = (question ?? "") + "\n" + String(conversation.suffix(900))
                    let extra = self?.searchTerms ?? []
                    relevantText = await Task.detached { CodeContext.relevant(root: root, text: searchText, extra: extra) }.value
                }
                MeetingLog.shared.write("code_context", ["hint": hintID, "repo": root, "cached": self?.codeCache?.root == root,
                                                         "overview_chars": overviewText.count, "relevant_chars": relevantText.count,
                                                         "relevant": relevantText, "ms": Int(Date().timeIntervalSince(requested) * 1000)])
            }
            guard !Task.isCancelled, let self else { return }
            let prompt = Self.prompt(conversation: conversation, question: question, overview: overviewText, relevant: relevantText,
                                     previous: previous, title: title, role: role)
            self.refreshCodeCache()
            MeetingLog.shared.write("hint_request", ["hint": hintID, "question": question ?? "", "provider": env.ai.provider.rawValue,
                                                     "model": model.id, "prompt_chars": prompt.count, "prompt": prompt,
                                                     "prep_ms": Int(Date().timeIntervalSince(requested) * 1000)])
            let firstToken = FirstToken()
            do {
                try await env.ai.quick(prompt: prompt, system: Self.system, provider: model.provider, model: model.model) { delta in
                    if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { firstToken.mark(hintID, since: requested) }
                    Task { @MainActor in self.append(delta, to: id) }
                }
                await Task.yield()
                self.finish(id, error: nil)
            } catch {
                self.finish(id, error: Task.isCancelled ? nil : error)
                MeetingLog.shared.write("hint_error", ["hint": hintID, "cancelled": Task.isCancelled, "message": error.localizedDescription])
            }
            let text = self.hints.first { $0.id == id }?.text ?? ""
            MeetingLog.shared.write("hint_done", ["hint": hintID, "total_ms": Int(Date().timeIntervalSince(requested) * 1000),
                                                  "cancelled": Task.isCancelled, "shown": self.hints.contains { $0.id == id }, "answer": text])
        }
    }

    private func append(_ delta: String, to id: UUID) {
        guard let i = hints.firstIndex(where: { $0.id == id }), hints[i].isStreaming else { return }
        hints[i].text += delta
    }

    private func finish(_ id: UUID, error: Error?) {
        if hints.first?.id == id { isThinking = false }
        guard let i = hints.firstIndex(where: { $0.id == id }) else { return }
        hints[i].isStreaming = false
        if let error, !(error is CancellationError) {
            if case AIError.cancelled = error { } else {
                hints[i].isError = true
                hints[i].text = error.localizedDescription
            }
        }
        // Auto hints with nothing to add just disappear.
        if hints[i].isEmptyAnswer, hints[i].question == nil { hints.remove(at: i) }
    }

    private func prepareOverview() {
        guard let root = repoRoot, overview?.root != root else { return }
        Task {
            let text = await Task.detached { CodeContext.overview(root: root) }.value
            if self.repoRoot == root { self.overview = (root, text) }
        }
    }

    // MARK: Prompt

    static let system = "Ты — незаметный суфлёр на рабочей встрече. Отвечаешь мгновенно, очень коротко, строго в заданном формате. \(AppLanguage.replyInstruction) Метки строк (ВАРИАНТ:, СКАЗАТЬ:, КОД:, РИСК:, СПРОСИТЬ:) не переводи."

    /// Stable parts first (instructions, project overview) so servers with prompt caching reuse them between hints.
    static func prompt(conversation: String, question: String?, overview: String, relevant: String, previous: [String],
                       title: String?, role: String) -> String {
        var parts: [String] = []
        parts.append("""
        Ты — суфлёр пользователя («Я») на рабочей встрече. Кто он: \(role). \
        Он глубоко знает тему и код. Твоя цель — чтобы он звучал как самый сильный инженер в комнате: \
        конкретные решения и их цена, а не общие слова и не вопросы новичка.

        Сначала молча пойми по последним репликам: какую проблему сейчас обсуждают, какие ограничения уже названы \
        (требования, регуляторика, совместимость, что уже отвергли), к какому решению склоняются.

        Что выдавать:
        - Обсуждают проблему или выбирают подход → главное 2–3 строки ВАРИАНТ: разные технические способы решения \
        (как именно сделать: данные, связи, где в системе), у каждого — плюс и минус через «+» и «−». Лучший первым. \
        Не предлагай то, что противоречит названным ограничениям или уже отвергнуто.
        - Можно одну строку СКАЗАТЬ — готовая фраза-рекомендация или аргумент.
        - КОД — только если в контексте кода реально есть связанное место (файл, функция), иначе не пиши.
        - РИСК — только неочевидный и новый.
        - СПРОСИТЬ — максимум одна строка и только если без ответа нельзя выбрать вариант.

        Формат — только строки с метками, без вступлений и Markdown:
        ВАРИАНТ: … + … − …
        СКАЗАТЬ: …
        КОД: …
        РИСК: …
        СПРОСИТЬ: …

        Правила: до 4 строк, каждая до 30 слов. Расшифровка с ошибками распознавания — восстанавливай термины и аббревиатуры по смыслу. \
        Не повторяй прошлые подсказки и их темы: если тема та же, продвинь её дальше (следующий шаг, детали реализации), а не перефразируй. \
        Если ничего действительно ценного нет — ответь одним символом «—».
        """)
        if !overview.isEmpty { parts.append("Проект:\n\(overview)") }
        if let title { parts.append("Встреча: \(title)") }
        if !relevant.isEmpty { parts.append("Код по теме разговора:\n\(relevant)") }
        if !previous.isEmpty { parts.append("Прошлые подсказки (не повторять):\n" + previous.joined(separator: "\n")) }
        parts.append("Расшифровка разговора (распознавание речи, возможны ошибки; говорящие не размечены — определяй по смыслу; последние реплики внизу):\n\(conversation.isEmpty ? "(пока пусто)" : conversation)")
        if let question {
            parts.append("Пользователь просит прямо сейчас: «\(question)». Ответь на это в том же формате, можно до 5 строк.")
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Code context

/// Quick, local view of a repository for the prompt: structure plus lines matching the conversation.
/// Plain `git` calls, a few dozen milliseconds each — no agent, no waiting.
enum CodeContext {
    static func overview(root: String) -> String {
        let name = (root as NSString).lastPathComponent
        let branch = git(["rev-parse", "--abbrev-ref", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let log = git(["log", "-8", "--format=%s"], in: root)
        let changed = git(["status", "--short"], in: root).split(separator: "\n").prefix(15).joined(separator: "\n")
        let files = git(["ls-files"], in: root).split(separator: "\n").map(String.init).filter { !isNoise($0) }

        var out = "Репозиторий: \(name) (ветка \(branch))\nПоследние коммиты:\n\(log.trimmingCharacters(in: .whitespacesAndNewlines))"
        if !changed.isEmpty { out += "\nНезакоммиченные изменения:\n\(changed)" }
        out += "\nФайлы (\(files.count)):\n" + fileList(files)
        if let readme = ["README.md", "readme.md", "README"].lazy.compactMap({ try? String(contentsOfFile: root + "/" + $0, encoding: .utf8) }).first {
            out += "\nREADME (начало):\n" + readme.split(separator: "\n", omittingEmptySubsequences: false).prefix(30).joined(separator: "\n").prefix(1000)
        }
        return String(out.prefix(5000))
    }

    /// Code related to the conversation: files ranked by how many different conversation terms they contain,
    /// with their most relevant lines. Generic words alone never pull a file in.
    static func relevant(root: String, text: String, extra: [String]) -> String {
        let terms = keywords(text, extra: extra)
        guard !terms.isEmpty else { return "" }
        var score: [String: (terms: Int, hits: Int)] = [:]
        for term in terms {
            let out = git(["grep", "-c", "-I", "-E", "-e", pattern(term), "--", "."] + excludes, in: root)
            for line in out.split(separator: "\n") {
                guard let colon = line.lastIndex(of: ":"), let n = Int(line[line.index(after: colon)...]) else { continue }
                let file = String(line[..<colon])
                guard !isNoise(file) else { continue }
                let old = score[file] ?? (0, 0)
                score[file] = (old.terms + 1, old.hits + n)
            }
        }
        let ranked = score.filter { $0.value.terms >= min(2, terms.count) }
            .sorted { $0.value.terms != $1.value.terms ? $0.value.terms > $1.value.terms : $0.value.hits < $1.value.hits }
            .prefix(5)
        var out: [String] = []
        for (file, s) in ranked {
            var args = ["grep", "-n", "-I", "-E"]
            for t in terms { args += ["-e", pattern(t)] }
            let lines = git(args + ["--", file], in: root).split(separator: "\n").map(String.init)
            // Lines with more terms first, real code before comments.
            let best = lines.map { line -> (String, Int) in
                let body = line.drop { $0 != ":" }.dropFirst().drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces)
                let lower = body.lowercased()
                var rank = terms.filter { lower.contains($0) }.count * 10
                if body.hasPrefix("//") || body.hasPrefix("#") || body.hasPrefix("*") || body.hasPrefix("/*") { rank -= 5 }
                return (line, rank)
            }.sorted { $0.1 > $1.1 }.prefix(4).map { String($0.0.prefix(220)) }
            out.append("\(file) (терминов: \(s.terms))\n" + best.map { "  " + $0 }.joined(separator: "\n"))
        }
        return String(out.joined(separator: "\n").prefix(3000))
    }

    /// The term as a name part, not inside another word: `sim`, `simId`, `isSim`, `SIM_CARD` — but not `similar`.
    private static func pattern(_ term: String) -> String {
        let lower = term.lowercased()
        let cap = lower.prefix(1).uppercased() + lower.dropFirst()
        let upper = lower.uppercased()
        return "(^|[^A-Za-z])(\(lower)|\(cap)|\(upper))([^a-z]|$)|[a-z0-9](\(cap)|\(upper))([^a-z]|$)"
    }

    private static let excludes = [":(exclude)*.md", ":(exclude)*.yaml", ":(exclude)*.yml", ":(exclude)*.config.*", ":(exclude)ci/*", ":(exclude)test/*", ":(exclude)tests/*", ":(exclude)*_test.*",
                                   ":(exclude)*.test.*", ":(exclude)*.spec.*", ":(exclude,glob)**/locales/**", ":(exclude,glob)**/i18n/**", ":(exclude,glob)**/test/**", ":(exclude,glob)**/tests/**", ":(exclude)*.lock", ":(exclude)*.resolved", ":(exclude)Vendor/*", ":(exclude)vendor/*",
                                   ":(exclude)node_modules/*", ":(exclude)*.min.js", ":(exclude)*.svg", ":(exclude)*.json"]

    private static func isNoise(_ path: String) -> Bool {
        let lower = path.lowercased()
        let junk = ["node_modules/", "vendor/", ".build/", "dist/", "build/", "pods/", ".lock", ".png", ".jpg", ".jpeg", ".gif",
                    ".ico", ".icns", ".svg", ".woff", ".ttf", ".mp3", ".wav", ".pdf", ".zip", "package.resolved"]
        return junk.contains { lower.contains($0) }
    }

    /// Compact tree: every file when the project is small, otherwise folders with counts plus source files.
    private static func fileList(_ files: [String]) -> String {
        if files.count <= 80 { return files.joined(separator: "\n") }
        var dirs: [String: Int] = [:]
        for f in files {
            let comps = f.split(separator: "/")
            let key = comps.count > 2 ? comps.prefix(2).joined(separator: "/") : (comps.count == 2 ? String(comps[0]) : ".")
            dirs[key, default: 0] += 1
        }
        let summary = dirs.sorted { $0.key < $1.key }.map { "\($0.key)/ — \($0.value)" }.joined(separator: "\n")
        return String(summary.prefix(2000))
    }

    private static let stopwords: Set<String> = [
        "это", "что", "как", "так", "вот", "если", "когда", "потому", "чтобы", "только", "можно", "нужно", "надо", "будет", "было",
        "есть", "нет", "они", "оно", "она", "его", "её", "мне", "тебе", "нам", "вам", "там", "тут", "здесь", "сейчас", "тогда",
        "просто", "вообще", "короче", "давай", "давайте", "хорошо", "ладно", "понятно", "значит", "например", "который", "которые",
        "которая", "какой", "какие", "тоже", "также", "очень", "потом", "сначала", "получается", "смысле", "собеседник",
        "the", "and", "for", "that", "this", "with", "you", "are", "was", "have", "not", "but", "can", "will", "okay",
    ]

    /// Search terms for the conversation: identifiers said as-is (latin words), plus the terms the model
    /// derived from the conversation in the background (`extra`). No per-project dictionaries.
    static func keywords(_ text: String, extra: [String] = []) -> [String] {
        var weight: [String: Int] = [:]
        for (i, term) in extra.enumerated() {
            let t = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, t.range(of: "^[a-z0-9_]+$", options: .regularExpression) != nil else { continue }
            weight[t, default: 0] += 10 - min(i, 8)
        }
        let tokens = text.components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "_")).inverted)
        for (i, raw) in tokens.enumerated() {
            let t = raw.lowercased()
            guard !stopwords.contains(t), t.range(of: "^[a-z_][a-z0-9_]{2,}$", options: .regularExpression) != nil else { continue }
            weight[t, default: 0] += i > tokens.count * 2 / 3 ? 4 : 2
        }
        return weight.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key).prefix(8).map { $0 }
    }

    private static func git(_ args: [String], in root: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readAll()
        p.waitUntilExit()
        return String(decoding: data.prefix(200_000), as: UTF8.self)
    }
}

/// Logs the moment the first piece of an answer arrives (latency the user actually feels).
private final class FirstToken: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func mark(_ hint: String, since start: Date) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        MeetingLog.shared.write("hint_first_token", ["hint": hint, "ms": Int(Date().timeIntervalSince(start) * 1000)])
    }
}
