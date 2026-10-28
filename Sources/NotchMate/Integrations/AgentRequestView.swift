import SwiftUI
import AppKit

/// A Claude Code / Codex question, plan or permission request answered right in the notch.
struct AgentRequestView: View {
    let request: AgentRequest
    @EnvironmentObject private var agents: AgentMonitor
    @EnvironmentObject private var vm: NotchViewModel
    @State private var selected: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var page = 0
    @FocusState private var focused: String?

    private var tint: Color { request.agent.tint }

    private var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: request.questions.map { ($0.text, answer(for: $0)) })
    }

    private func answer(for question: AgentQuestion) -> String {
        let picked = question.options.map(\.label).filter { selected[question.text, default: []].contains($0) }
        let text = (custom[question.text] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (picked + (text.isEmpty ? [] : [text])).joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                switch request.kind {
                case .question: questionPage
                case .plan: planBody
                case .permission: permissionBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(14)
        .background(background)
        .padding(.horizontal, 12)
        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        .onChange(of: focused) { _, value in vm.isTyping = value != nil }
        .onDisappear { vm.isTyping = false }
        .onReceive(NotificationCenter.default.publisher(for: .notchMateAgentKey)) { note in
            guard let key = note.object as? AgentRequestKey, agents.requests.first?.id == request.id else { return }
            switch key {
            case .option(let n):
                guard request.kind == .question else { return }
                let question = request.questions[min(page, request.questions.count - 1)]
                guard question.options.indices.contains(n - 1) else { return }
                toggle(question.options[n - 1].label, in: question)
            case .submit:
                // Approvals stay a deliberate click; Return only moves through questions.
                advance()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    // MARK: Chrome

    private var background: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.16), Color.white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [tint.opacity(0.55), Color.white.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
            )
            .shadow(color: tint.opacity(0.18), radius: 14, y: 4)
    }

    private var header: some View {
        HStack(spacing: 10) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font(13, .bold)).foregroundStyle(.white).lineLimit(1)
                HStack(spacing: 4) {
                    Text(request.project).lineLimit(1)
                    if let host = request.hostName {
                        Text("·")
                        Text(host).lineLimit(1)
                    }
                }
                .font(Theme.font(10, .medium)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            if agents.requests.count > 1 {
                Text(String(localized: "ещё \(agents.requests.count - 1)"))
                    .font(Theme.font(10, .semibold)).foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Capsule().fill(Theme.surface))
            }
            countdown
        }
    }

    private var title: String {
        switch request.kind {
        case .question: return String(localized: "\(request.agent.title) спрашивает")
        case .plan: return String(localized: "\(request.agent.title) предлагает план")
        case .permission: return String(localized: "\(request.agent.title) просит разрешение")
        }
    }

    private var symbol: String {
        switch request.kind {
        case .question: return "questionmark.bubble.fill"
        case .plan: return "list.bullet.clipboard.fill"
        case .permission: return request.toolSymbol
        }
    }

    private var badge: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 0.6))
            if let icon = hostIcon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .frame(width: 16, height: 16)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: 5, y: 5)
            }
        }
    }

    /// Icon of the app the agent runs in: Terminal, an IDE, or the agent's own desktop app.
    private var hostIcon: NSImage? {
        if let id = request.hostBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return request.agent.icon
    }

    /// Time left before the agent falls back to asking in its own window.
    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, AgentMonitor.requestTimeout - ctx.date.timeIntervalSince(request.createdAt))
            ZStack {
                Ring(progress: left / AgentMonitor.requestTimeout, tint: left < 15 ? .orange : tint, lineWidth: 2.5)
                Text("\(Int(left.rounded(.up)))").font(Theme.font(9, .bold)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
            }
            .frame(width: 26, height: 26)
            .animation(.linear(duration: 1), value: left)
        }
        .help(String(localized: "Потом вопрос вернётся в окно агента"))
    }

    // MARK: Question

    @ViewBuilder private var questionPage: some View {
        let question = request.questions[min(page, request.questions.count - 1)]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if !question.header.isEmpty {
                    Text(question.header.uppercased())
                        .font(Theme.font(9, .bold)).tracking(0.6).foregroundStyle(tint)
                        .padding(.horizontal, 7).frame(height: 18)
                        .background(Capsule().fill(tint.opacity(0.15)))
                }
                if question.multiple {
                    Text(String(localized: "можно несколько")).font(Theme.font(10, .medium)).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                if request.questions.count > 1 { steps }
            }
            Text(question.text)
                .font(Theme.font(14, .semibold)).foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                        OptionRow(index: index + 1, option: option, multiple: question.multiple, tint: tint,
                                  isOn: selected[question.text, default: []].contains(option.label)) {
                            toggle(option.label, in: question)
                        }
                    }
                    if question.allowsCustom { customField(question) }
                }
                .padding(.bottom, 2)
            }
        }
        .id(page)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
    }

    private var steps: some View {
        HStack(spacing: 4) {
            ForEach(request.questions.indices, id: \.self) { index in
                let done = !answer(for: request.questions[index]).isEmpty
                Capsule()
                    .fill(index == page ? tint : (done ? tint.opacity(0.45) : Color.white.opacity(0.18)))
                    .frame(width: index == page ? 16 : 6, height: 6)
                    .onTapGesture { withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { page = index } }
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: page)
    }

    private func toggle(_ label: String, in question: AgentQuestion) {
        withAnimation(.easeOut(duration: 0.15)) {
            var value = selected[question.text, default: []]
            if question.multiple {
                if value.contains(label) { value.remove(label) } else { value.insert(label) }
            } else {
                value = [label]
                custom[question.text] = ""
            }
            selected[question.text] = value
        }
    }

    private func customField(_ question: AgentQuestion) -> some View {
        let binding = Binding(get: { custom[question.text] ?? "" }, set: { value in
            custom[question.text] = value
            if !question.multiple && !value.isEmpty { selected[question.text] = [] }
        })
        let active = focused == question.text || !(custom[question.text] ?? "").isEmpty
        let placeholder = question.options.isEmpty ? String(localized: "Ваш ответ…") : String(localized: "Свой вариант…")
        return HStack(spacing: 8) {
            Image(systemName: question.secret ? "lock.fill" : "pencil")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(active ? tint : Theme.secondary)
                .frame(width: 20)
            Group {
                if question.secret {
                    SecureField("", text: binding, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
                } else {
                    TextField("", text: binding, prompt: Text(placeholder).foregroundStyle(Theme.tertiary))
                }
            }
            .textFieldStyle(.plain).font(Theme.font(12)).foregroundStyle(.white)
            .focused($focused, equals: question.text)
            .onSubmit(advance)
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? tint.opacity(0.1) : Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(active ? tint.opacity(0.6) : Theme.stroke, lineWidth: active ? 1 : 0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.onRequestKey?(true); focused = question.text }
    }

    // MARK: Plan

    private var planBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array((request.input["plan"] as? String ?? "").components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                    PlanLine(line: line, tint: tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(codeBackground)
    }

    // MARK: Permission

    private var permissionBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(request.toolTitle).font(Theme.font(12, .semibold)).foregroundStyle(.white)
                if request.toolTitle != request.tool {
                    Text(request.tool).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(Theme.tertiary)
                }
            }
            if let summary = request.summary {
                Text(summary).font(Theme.font(11)).foregroundStyle(Theme.secondary).lineLimit(2)
            }
            ScrollView {
                HStack(alignment: .top, spacing: 6) {
                    if request.isCommand { Text("$").foregroundStyle(tint) }
                    Text(request.detail.isEmpty ? String(localized: "Подробности доступны в приложении агента.") : request.detail)
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11.5, design: .monospaced))
                .padding(12)
            }
            .background(codeBackground)
        }
    }

    private var codeBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 0.5))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: openInApp) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
                    Text(String(localized: "Открыть \(request.hostName ?? request.agent.title)")).lineLimit(1)
                }
                .font(Theme.font(11, .semibold)).foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help(String(localized: "Вернуть запрос в окно агента"))
            Spacer()
            switch request.kind {
            case .question:
                if page > 0 {
                    PillButton(title: String(localized: "Назад"), icon: "chevron.left") { go(to: page - 1) }
                }
                let isLast = page >= request.questions.count - 1
                let ready = isLast ? !answers.values.contains(where: \.isEmpty) : !answer(for: request.questions[page]).isEmpty
                PillButton(title: isLast ? String(localized: "Ответить") : String(localized: "Далее"),
                           icon: isLast ? "paperplane.fill" : "chevron.right", tint: tint, prominent: true, action: advance)
                    .disabled(!ready).opacity(ready ? 1 : 0.4)
            case .plan:
                PillButton(title: String(localized: "Доработать"), icon: "arrow.uturn.backward") { submit(false) }
                PillButton(title: String(localized: "Принять план"), icon: "checkmark", tint: tint, prominent: true) { submit(true) }
            case .permission:
                PillButton(title: String(localized: "Отклонить"), icon: "xmark", tint: Color(red: 1, green: 0.45, blue: 0.42)) { submit(false) }
                PillButton(title: String(localized: "Разрешить"), icon: "checkmark", tint: tint, prominent: true) { submit(true) }
            }
        }
    }

    private func go(to index: Int) {
        focused = nil
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { page = index }
    }

    private func advance() {
        guard request.kind == .question else { return }
        if page < request.questions.count - 1 {
            if !answer(for: request.questions[page]).isEmpty { go(to: page + 1) }
        } else if !answers.values.contains(where: \.isEmpty) {
            submit(true)
        }
    }

    private func openInApp() {
        agents.finishRequest(request.id, response: [:])
        let ids = (request.hostBundleID.map { [$0] } ?? []) + request.agent.appBundleIDs
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { app.activate(); break }
        }
    }

    private func submit(_ allow: Bool) {
        focused = nil
        withAnimation(.easeOut(duration: 0.2)) {
            agents.finishRequest(request.id, response: request.response(allow: allow, answers: answers))
        }
    }
}

/// One answer choice: number, label, description and a check that fills with the agent's color.
private struct OptionRow: View {
    let index: Int
    let option: AgentQuestion.Option
    let multiple: Bool
    let tint: Color
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Text("\(index)")
                    .font(Theme.font(10, .bold)).monospacedDigit()
                    .foregroundStyle(isOn ? Color.black : Theme.secondary)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? tint : Color.white.opacity(0.08)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(Theme.font(12, .semibold)).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    if !option.detail.isEmpty {
                        Text(option.detail).font(Theme.font(10.5)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? (multiple ? "checkmark.square.fill" : "checkmark.circle.fill") : (multiple ? "square" : "circle"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isOn ? tint : Theme.tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isOn ? tint.opacity(0.16) : (hovering ? Theme.surfaceHover : Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(isOn ? tint.opacity(0.7) : Theme.stroke, lineWidth: isOn ? 1 : 0.5))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityHint(option.detail)
    }
}

/// Lightweight Markdown for plans: headings, bullets, numbered steps and inline styles.
private struct PlanLine: View {
    let line: String
    let tint: Color

    var body: some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = CGFloat(line.prefix(while: { $0 == " " }).count / 2) * 12
        if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            inline(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces))
                .font(Theme.font(level <= 1 ? 14 : (level == 2 ? 13 : 12), .bold)).foregroundStyle(.white)
                .padding(.top, level <= 2 ? 4 : 2)
        } else if let rest = bullet(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle().fill(tint).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                inline(rest).font(Theme.font(11.5)).foregroundStyle(.white.opacity(0.88))
            }
            .padding(.leading, indent)
        } else if let step = numbered(trimmed) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(step.number).font(Theme.font(11, .bold)).monospacedDigit().foregroundStyle(tint)
                inline(step.rest).font(Theme.font(11.5)).foregroundStyle(.white.opacity(0.88))
            }
            .padding(.leading, indent)
        } else {
            inline(trimmed).font(Theme.font(11.5)).foregroundStyle(.white.opacity(0.8)).padding(.leading, indent)
        }
    }

    private func inline(_ text: String) -> Text {
        let styled = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(styled)
    }

    private func bullet(_ text: String) -> String? {
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where text.hasPrefix(marker) { return String(text.dropFirst(marker.count)) }
        return nil
    }

    private func numbered(_ text: String) -> (number: String, rest: String)? {
        let digits = text.prefix(while: \.isNumber)
        guard !digits.isEmpty, text.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return ("\(digits).", String(text.dropFirst(digits.count + 2)))
    }
}
