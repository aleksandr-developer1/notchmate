import AppKit
import SwiftUI

enum AIProvider: String, CaseIterable, Identifiable {
    case chatgpt, claude, openaiKey, anthropicKey, customOpenAI
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .openaiKey: return "OpenAI API"
        case .anthropicKey: return "Anthropic API"
        case .customOpenAI: return String(localized: "Своя ИИ")
        }
    }

    var subtitle: String {
        switch self {
        case .chatgpt: return String(localized: "аккаунт ChatGPT через Codex")
        case .claude: return String(localized: "аккаунт Claude через Claude Code")
        case .openaiKey: return String(localized: "ключ API")
        case .anthropicKey: return String(localized: "ключ API")
        case .customOpenAI: return String(localized: "OpenAI-совместимый сервер")
        }
    }

    var tint: Color {
        switch self {
        case .chatgpt, .openaiKey: return Color(red: 0.2, green: 0.8, blue: 0.6)
        case .claude, .anthropicKey: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .customOpenAI: return Color(red: 0.45, green: 0.62, blue: 0.95)
        }
    }

    var symbol: String {
        switch self {
        case .chatgpt, .claude: return "person.crop.circle.fill"
        case .openaiKey, .anthropicKey: return "key.fill"
        case .customOpenAI: return "server.rack"
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String            // "user" | "assistant"
    var text: String
    var isStreaming = false
    var isError = false
}

@MainActor
final class TextBox { var text = "" }

@MainActor
final class AIChatService: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isResponding = false
    @Published var draft = ""

    let codex = CodexAppServer()
    let claude = ClaudeCodeCLI()
    private let settings = Settings.shared
    private var task: Task<Void, Never>?

    /// Fired when a response starts / finishes (companion reactions).
    var onRespondingChanged: ((Bool) -> Void)?
    var onAssistantError: ((String) -> Void)?

    nonisolated static let toolsHint = "У тебя есть инструменты NotchMate: сводка дня, заметки Obsidian (добавить, найти), фокус-таймер, Jira (списание времени — только по явной просьбе), календарь, музыка. Используй их, когда просят что-то сделать или узнать про день."

    // Plain constants: read by the backends off the main actor.
    nonisolated static let systemPrompt = """
    Ты — встроенный помощник в приложении «NotchMate» на macOS. Отвечай кратко и по делу. \(AppLanguage.replyInstruction) Если пользователь пишет на другом языке, отвечай на его языке. \
    Используй Markdown умеренно: короткие списки и `код`, без больших заголовков — окно небольшое.
    """

    var provider: AIProvider {
        get { settings.aiProvider }
        set { settings.aiProvider = newValue; newChat() }
    }

    func start() {
        Task { await claude.refreshStatus() }
        if codex.isInstalled { Task { await codex.refreshAccount() } }
    }

    func isReady(_ p: AIProvider) -> Bool {
        switch p {
        case .chatgpt: return codex.isLoggedIn
        case .claude: return claude.isLoggedIn
        case .openaiKey: return !(Keychain.get(OpenAIKeyBackend.account) ?? "").isEmpty
        case .anthropicKey: return !(Keychain.get(AnthropicKeyBackend.account) ?? "").isEmpty
        case .customOpenAI: return !settings.aiCustomBaseURL.isEmpty && !settings.aiCustomModel.isEmpty
        }
    }

    func accountLabel(_ p: AIProvider) -> String {
        switch p {
        case .chatgpt:
            guard codex.isLoggedIn else { return String(localized: "не подключено") }
            return [codex.email, codex.plan?.capitalized].compactMap { $0 }.joined(separator: " · ")
        case .claude:
            guard claude.isLoggedIn else { return String(localized: "не подключено") }
            return claude.email ?? String(localized: "подключено")
        case .openaiKey, .anthropicKey:
            return isReady(p) ? String(localized: "ключ сохранён") : String(localized: "нет ключа")
        case .customOpenAI:
            return isReady(p) ? String(localized: "сервер настроен") : String(localized: "не настроено")
        }
    }

    func newChat() {
        stop()
        messages.removeAll()
        codex.resetThread()
        claude.resetSession()
    }

    func stop() {
        task?.cancel()
        codex.cancel()
        claude.cancel()
        if isResponding { setResponding(false) }
    }

    func send(_ raw: String? = nil) {
        let text = (raw ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        draft = ""
        messages.append(ChatMessage(role: "user", text: text))
        messages.append(ChatMessage(role: "assistant", text: "", isStreaming: true))
        let replyID = messages.last!.id
        let history = messages.dropLast().filter { !$0.isError }.map { AITurn(role: $0.role, text: $0.text) }
        let provider = self.provider
        setResponding(true)

        let tools = settings.aiToolsEnabled
        let system = Self.systemPrompt + (tools ? "\n\n" + Self.toolsHint + "\n\nКонтекст пользователя сейчас:\n" + NotchMateToolRunner.todaySummary(env: AppEnvironment.shared) : "")
        let runner: ToolCalling.Runner = { name, args in
            await NotchMateToolRunner.run(name, args, env: AppEnvironment.shared)
        }

        task = Task { [weak self] in
            guard let self else { return }
            let append: @Sendable (String) -> Void = { delta in
                Task { @MainActor in self.appendDelta(delta, to: replyID) }
            }
            do {
                try await self.route(provider: provider, text: text, history: Array(history), system: system, instructions: Self.systemPrompt,
                                     tools: tools, runner: runner, codex: self.codex, claude: self.claude, onDelta: append)
                await Task.yield()
                self.finish(replyID, error: nil)
            } catch is CancellationError {
                self.finish(replyID, error: AIError.cancelled)
            } catch {
                self.finish(replyID, error: error)
            }
        }
    }

    /// Sends one turn to the selected provider. Account providers keep their own thread/session inside `codex`/`claude`.
    private func route(provider: AIProvider, text: String, history: [AITurn], system: String, instructions: String,
                       tools: Bool, runner: @escaping ToolCalling.Runner, codex: CodexAppServer, claude: ClaudeCodeCLI,
                       model override: String? = nil, quick: Bool = false, onDelta append: @escaping @Sendable (String) -> Void) async throws {
                switch provider {
                case .chatgpt:
                    try await codex.send(text, model: override ?? self.settings.aiCodexModel, instructions: instructions, quick: quick) { d in append(d) }
                case .claude:
                    try await claude.send(text, model: override ?? self.settings.aiClaudeModel, instructions: instructions,
                                          allowTools: tools, quick: quick) { d in append(d) }
                case .openaiKey:
                    guard let key = Keychain.get(OpenAIKeyBackend.account), !key.isEmpty else { throw AIError.message(String(localized: "Добавьте ключ OpenAI в настройках")) }
                    if tools {
                        try await ToolCalling.openAICompatible(baseURL: "https://api.openai.com/v1", key: key, model: self.settings.aiOpenAIModel,
                                                               system: system, history: history, runTool: runner, onDelta: append)
                    } else {
                        try await OpenAIKeyBackend.stream(history: history, model: override ?? self.settings.aiOpenAIModel, key: key,
                                                          system: quick ? system : nil, onDelta: append)
                    }
                case .anthropicKey:
                    guard let key = Keychain.get(AnthropicKeyBackend.account), !key.isEmpty else { throw AIError.message(String(localized: "Добавьте ключ Anthropic в настройках")) }
                    if tools {
                        try await ToolCalling.anthropic(key: key, model: self.settings.aiAnthropicModel, system: system,
                                                        history: history, runTool: runner, onDelta: append)
                    } else {
                        try await AnthropicKeyBackend.stream(history: history, model: override ?? self.settings.aiAnthropicModel,
                                                             key: key, system: quick ? system : nil, maxTokens: quick ? 600 : nil, onDelta: append)
                    }
                case .customOpenAI:
                    let key = Keychain.get(CustomOpenAIBackend.account) ?? ""
                    guard !self.settings.aiCustomBaseURL.isEmpty else { throw AIError.message(String(localized: "Добавьте Base URL своей ИИ в настройках")) }
                    guard !self.settings.aiCustomModel.isEmpty else { throw AIError.message(String(localized: "Добавьте модель своей ИИ в настройках")) }
                    if tools {
                        do {
                            try await ToolCalling.openAICompatible(baseURL: self.settings.aiCustomBaseURL, key: key, model: self.settings.aiCustomModel,
                                                                   system: system, history: history, runTool: runner, onDelta: append)
                        } catch AIError.message(let m) where m.hasPrefix("HTTP 400") || m.hasPrefix("HTTP 422") {
                            // Server without function calling — fall back to plain chat.
                            try await CustomOpenAIBackend.stream(history: history, model: self.settings.aiCustomModel, baseURL: self.settings.aiCustomBaseURL, key: key, onDelta: append)
                        }
                    } else {
                        try await CustomOpenAIBackend.stream(history: history, model: override ?? self.settings.aiCustomModel, baseURL: self.settings.aiCustomBaseURL, key: key,
                                                             system: quick ? system : nil, maxTokens: quick ? 600 : nil, onDelta: append)
                    }
                }
    }

    // MARK: Ask Taby (short answers in the companion's speech bubble)

    @Published private(set) var tabyAnswer = ""
    @Published private(set) var tabyQuestion = ""
    @Published private(set) var tabyThinking = false
    private let tabyCodex = CodexAppServer()
    private let tabyClaude = ClaudeCodeCLI()
    private var tabyTask: Task<Void, Never>?

    static func tabyPersona(name: String) -> String {
        "Ты — \(name), маленький дружелюбный помощник, живущий под вырезом камеры MacBook. \(AppLanguage.replyInstruction) Отвечай 1–3 короткими предложениями, без Markdown и списков, по-человечески и по делу. Опирайся на контекст дня пользователя."
    }

    func askTaby(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        tabyTask?.cancel()
        tabyQuestion = question
        tabyAnswer = ""
        tabyThinking = true
        onRespondingChanged?(true)
        let env = AppEnvironment.shared
        let persona = Self.tabyPersona(name: settings.companionName)
        let context = NotchMateToolRunner.todaySummary(env: env)
        let tools = settings.aiToolsEnabled
        let system = persona + (tools ? "\n\n" + Self.toolsHint : "") + "\n\nКонтекст пользователя сейчас:\n" + context
        let prompt = "Контекст дня:\n\(context)\n\nВопрос: \(question)"
        let provider = self.provider
        let runner: ToolCalling.Runner = { name, args in await NotchMateToolRunner.run(name, args, env: AppEnvironment.shared) }
        tabyCodex.resetThread()
        tabyClaude.resetSession()
        tabyTask = Task { [weak self] in
            guard let self else { return }
            let append: @Sendable (String) -> Void = { d in
                Task { @MainActor in
                    // Hide tool-call markers from the bubble.
                    if d.hasPrefix("`⚙︎") || d.hasPrefix("\n\n`⚙︎") { return }
                    self.tabyAnswer += d
                }
            }
            do {
                let isAccount = provider == .chatgpt || provider == .claude
                try await self.route(provider: provider, text: isAccount ? prompt : question,
                                     history: [AITurn(role: "user", text: question)], system: system, instructions: persona,
                                     tools: tools, runner: runner, codex: self.tabyCodex, claude: self.tabyClaude, onDelta: append)
            } catch is CancellationError {
            } catch {
                self.tabyAnswer = String(localized: "Не получилось ответить: \(error.localizedDescription)")
            }
            self.tabyAnswer = self.tabyAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.tabyAnswer.isEmpty { self.tabyAnswer = String(localized: "Хм, не нашёлся с ответом.") }
            self.tabyThinking = false
            self.onRespondingChanged?(false)
        }
    }

    /// One-off request used by features (call summaries). `preferLocal` routes to the user's own server when configured.
    func oneShot(prompt: String, system: String, preferLocal: Bool = false) async throws -> String {
        var provider = self.provider
        if preferLocal, isReady(.customOpenAI) { provider = .customOpenAI }
        let codex = CodexAppServer()
        let claude = ClaudeCodeCLI()
        let runner: ToolCalling.Runner = { _, _ in ("", true) }
        let box = TextBox()
        try await route(provider: provider, text: prompt, history: [AITurn(role: "user", text: prompt)],
                        system: system, instructions: system, tools: false, runner: runner,
                        codex: codex, claude: claude) { delta in Task { @MainActor in box.text += delta } }
        codex.stop()
        return box.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Meeting assistant (streamed one-offs, own long-lived backends so each hint starts fast)

    private let quickCodex = CodexAppServer()
    private let quickClaude = ClaudeCodeCLI()
    // Background helper requests run next to a hint without cancelling it.
    private let auxCodex = CodexAppServer()
    private let auxClaude = ClaudeCodeCLI()

    /// Streams a single request without chat history to an explicit provider and model.
    func quick(prompt: String, system: String, provider: AIProvider, model: String, aux: Bool = false,
               onDelta: @escaping @Sendable (String) -> Void) async throws {
        let codex = aux ? auxCodex : quickCodex
        let claude = aux ? auxClaude : quickClaude
        codex.resetThread()
        claude.resetSession()
        let runner: ToolCalling.Runner = { _, _ in ("", true) }
        try await route(provider: provider, text: prompt, history: [AITurn(role: "user", text: prompt)],
                        system: system, instructions: system, tools: false, runner: runner,
                        codex: codex, claude: claude, model: model, quick: true, onDelta: onDelta)
    }

    /// Models of the ChatGPT account (loaded by the Codex app server).
    var codexModelIDs: [String] { codex.models.map(\.id) }

    func cancelQuick() {
        quickCodex.cancel()
        quickClaude.cancel()
    }

    func stopTaby() {
        tabyTask?.cancel()
        tabyCodex.cancel()
        tabyClaude.cancel()
        tabyThinking = false
        onRespondingChanged?(false)
    }

    private func appendDelta(_ delta: String, to id: UUID) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].text += delta
    }

    private func finish(_ id: UUID, error: Error?) {
        if let i = messages.firstIndex(where: { $0.id == id }) {
            messages[i].isStreaming = false
            if let error {
                if case AIError.cancelled = error {
                    if messages[i].text.isEmpty { messages[i].text = String(localized: "_Остановлено_") }
                } else {
                    messages[i].isError = true
                    messages[i].text = (messages[i].text.isEmpty ? "" : messages[i].text + "\n\n") + error.localizedDescription
                    onAssistantError?(error.localizedDescription)
                }
            } else if messages[i].text.isEmpty {
                messages[i].text = String(localized: "_Пустой ответ_")
            }
        }
        setResponding(false)
    }

    private func setResponding(_ value: Bool) {
        isResponding = value
        onRespondingChanged?(value)
    }
}
