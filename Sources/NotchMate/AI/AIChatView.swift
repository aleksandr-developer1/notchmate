import AppKit
import SwiftUI

struct AIChatView: View {
    @EnvironmentObject var ai: AIChatService
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var clipboard: ClipboardHistory
    @ObservedObject var settings = Settings.shared
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            header
            if !ai.isReady(ai.provider) {
                connectPrompt
            } else {
                messagesList
                inputBar
            }
        }
        .onChange(of: inputFocused) { _, f in vm.isTyping = f }
        .onReceive(NotificationCenter.default.publisher(for: .notchMateFocusAI)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { inputFocused = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(AIProvider.allCases) { p in
                    Button {
                        ai.provider = p
                    } label: {
                        Label("\(p.title) — \(ai.accountLabel(p))", systemImage: p == ai.provider ? "checkmark" : p.symbol)
                    }
                }
                Divider()
                Button("Настройки ИИ…") { NotificationCenter.default.post(name: .notchMateOpenSettings, object: nil) }
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(ai.provider.tint).frame(width: 8, height: 8)
                    Text(ai.provider.title).font(Theme.font(13, .bold)).foregroundStyle(.white)
                    Text(ai.accountLabel(ai.provider)).font(Theme.font(11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            if ai.provider == .chatgpt, let used = ai.codex.usedPercent {
                HStack(spacing: 4) {
                    Ring(progress: used / 100, tint: used > 80 ? .orange : ai.provider.tint, lineWidth: 2.5).frame(width: 12, height: 12)
                    Text("\(Int(used))% лимита").font(Theme.font(10, .medium)).foregroundStyle(Theme.tertiary)
                }
                .help(ai.codex.resetsAt.map { "Сбросится \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            }
            IconButton(systemName: "square.and.pencil", size: 11, frame: 26, help: "Новый чат") { ai.newChat() }
        }
    }

    // MARK: Connect

    private var connectPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 28)).foregroundStyle(ai.provider.tint)
            Text("Подключите \(ai.provider.title)").font(Theme.font(15, .bold)).foregroundStyle(.white)
            Text(connectHint).font(Theme.font(12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                switch ai.provider {
                case .chatgpt:
                    PillButton(title: ai.codex.loginInProgress ? "Ждём браузер…" : "Войти через ChatGPT", icon: "person.crop.circle", tint: ai.provider.tint, prominent: true) {
                        Task { await ai.codex.login() }
                    }
                case .claude:
                    PillButton(title: "Войти в Claude", icon: "person.crop.circle", tint: ai.provider.tint, prominent: true) { ai.claude.login() }
                case .openaiKey, .anthropicKey:
                    PillButton(title: "Добавить ключ", icon: "key.fill", tint: ai.provider.tint, prominent: true) {
                        NotificationCenter.default.post(name: .notchMateOpenSettings, object: nil)
                    }
                case .customOpenAI:
                    PillButton(title: "Настроить сервер", icon: "server.rack", tint: ai.provider.tint, prominent: true) {
                        NotificationCenter.default.post(name: .notchMateOpenSettings, object: nil)
                    }
                }
                PillButton(title: "Другой способ", icon: "arrow.left.arrow.right") {
                    NotificationCenter.default.post(name: .notchMateOpenSettings, object: nil)
                }
            }
            if let err = ai.codex.lastError, ai.provider == .chatgpt {
                Text(err).font(Theme.font(10)).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 16)
    }

    private var connectHint: String {
        switch ai.provider {
        case .chatgpt: return ai.codex.isInstalled ? "Вход через ваш аккаунт ChatGPT в браузере — используется подписка, без ключей" : "Нужен Codex CLI: npm i -g @openai/codex"
        case .claude: return ai.claude.isInstalled ? "Откроется Терминал со входом в Claude Code — используется ваша подписка Claude" : "Нужен Claude Code: brew install claude-code"
        case .openaiKey: return "Вставьте ключ OpenAI API в настройках"
        case .anthropicKey: return "Вставьте ключ Anthropic API в настройках"
        case .customOpenAI: return "Укажите Base URL, модель и API key в настройках"
        }
    }

    // MARK: Messages

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if ai.messages.isEmpty { suggestions }
                    ForEach(ai.messages) { msg in
                        MessageBubble(message: msg, tint: ai.provider.tint).id(msg.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 2)
            }
            .onChange(of: ai.messages) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Спросите что угодно или начните с готового:").font(Theme.font(12)).foregroundStyle(Theme.secondary)
            FlowChips(items: quickActions) { action in ai.send(action.prompt()) }
        }
        .padding(.top, 6)
    }

    private var lastClipText: String? {
        for item in clipboard.items { if case .text(let s) = item.kind { return s } }
        return nil
    }

    private var quickActions: [QuickAction] {
        var list: [QuickAction] = []
        if let clip = lastClipText {
            let snippet = String(clip.prefix(4000))
            list.append(QuickAction(title: "Объясни скопированное", icon: "doc.on.clipboard") { "Объясни простыми словами:\n\n\(snippet)" })
            list.append(QuickAction(title: "Переведи буфер", icon: "globe") { "Переведи на английский (если текст на английском — на русский):\n\n\(snippet)" })
            list.append(QuickAction(title: "Сократи буфер", icon: "text.redaction") { "Сократи до 2–3 предложений, сохранив смысл:\n\n\(snippet)" })
        }
        list.append(QuickAction(title: "План на день", icon: "checklist") { "Помоги спланировать рабочий день: предложи структуру с блоками фокуса и перерывами." })
        list.append(QuickAction(title: "Текст задачи для Jira", icon: "briefcase") { "Помоги сформулировать задачу для Jira: заголовок, описание, критерии приёмки. Сначала задай мне 2–3 уточняющих вопроса." })
        return list
    }

    // MARK: Input

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("", text: $ai.draft, prompt: Text("Сообщение \(ai.provider.title)…").foregroundStyle(Theme.tertiary), axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.font(13))
                .foregroundStyle(.white)
                .lineLimit(1...5)
                .focused($inputFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    ai.send(); return .handled
                }
                .padding(.vertical, 8)
            if ai.isResponding {
                IconButton(systemName: "stop.fill", size: 11, frame: 30, tint: .white, filled: true, help: "Остановить") { ai.stop() }
            } else {
                Button { ai.send() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(ai.draft.isEmpty ? Color.white.opacity(0.3) : ai.provider.tint))
                }
                .buttonStyle(PressableStyle())
                .disabled(ai.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.leading, 12).padding(.trailing, 5).padding(.vertical, 2)
        .card(radius: 18, fill: Color.white.opacity(inputFocused ? 0.1 : 0.06))
    }
}

struct QuickAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let prompt: () -> String
}

private struct FlowChips: View {
    let items: [QuickAction]
    let onTap: (QuickAction) -> Void
    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.prefix(4)) { item in
                PillButton(title: item.title, icon: item.icon) { onTap(item) }
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage
    let tint: Color

    var body: some View {
        HStack(alignment: .top) {
            if message.role == "user" { Spacer(minLength: 60) }
            VStack(alignment: .leading, spacing: 4) {
                if message.text.isEmpty && message.isStreaming {
                    TypingDots(tint: tint)
                } else {
                    MarkdownText(text: message.text, isUser: message.role == "user", isError: message.isError)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(message.role == "user" ? tint.opacity(0.22) : (message.isError ? Color.red.opacity(0.14) : Theme.surface))
            )
            .contextMenu {
                Button("Копировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                }
                Button("Сохранить в Obsidian") { _ = AppEnvironment.shared.obsidian.capture(message.text) }
            }
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }
}

private struct TypingDots: View {
    let tint: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(tint).frame(width: 6, height: 6)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.8)))
                }
            }
            .frame(height: 16)
        }
    }
}

/// Chat markdown: inline formatting plus fenced code blocks.
private struct MarkdownText: View {
    let text: String
    let isUser: Bool
    let isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if block.isCode {
                    Text(block.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35)))
                } else {
                    Text(attributed(block.text))
                        .font(Theme.font(13))
                        .foregroundStyle(isError ? Color.orange : .white.opacity(0.92))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var blocks: [(text: String, isCode: Bool)] {
        var out: [(String, Bool)] = []
        var current: [String] = []
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !current.isEmpty { out.append((current.joined(separator: "\n"), inCode)) }
                current = []
                inCode.toggle()
                continue
            }
            current.append(line)
        }
        if !current.isEmpty { out.append((current.joined(separator: "\n"), inCode)) }
        return out.map { (text: $0.0.trimmingCharacters(in: .newlines), isCode: $0.1) }.filter { !$0.text.isEmpty }
    }

    private func attributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

extension Notification.Name {
    static let notchMateFocusAI = Notification.Name("notchmate.focusAI")
}
