import AppKit
import SwiftUI

extension Theme {
    static let git = Color(red: 0.96, green: 0.42, blue: 0.24)
}

struct GitView: View {
    @EnvironmentObject var git: GitService

    var body: some View {
        if let status = git.status {
            HStack(alignment: .top, spacing: 10) {
                RepoCard(status: status).frame(width: 292)
                ChangesCard(status: status)
            }
            .onAppear { git.refresh(); git.refreshCI() }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.git)
            Text("Откройте проект в терминале или редакторе").font(Theme.font(14, .bold)).foregroundStyle(.white)
            Text("NotchMate сам поймёт, в каком репозитории вы работаете: ветка, изменения, CI и коммит в пару кликов")
                .font(Theme.font(11)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            if !git.recent.isEmpty {
                HStack(spacing: 6) {
                    ForEach(git.recent.prefix(4), id: \.self) { root in
                        PillButton(title: (root as NSString).lastPathComponent, icon: "folder.fill", tint: Theme.git) { git.select(root) }
                    }
                }
            }
            PillButton(title: "Выбрать папку…", icon: "plus", tint: Theme.git, prominent: git.recent.isEmpty) { GitSettings.chooseFolder() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 18)
    }
}

// MARK: - Repository

private struct RepoCard: View {
    let status: GitStatus
    @EnvironmentObject var git: GitService

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            branchRow
            counters
            if let c = status.lastCommit {
                HStack(spacing: 5) {
                    Text(c.hash).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.git.opacity(0.9))
                    Text(c.subject).font(Theme.font(11)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(c.when).font(Theme.font(10)).foregroundStyle(Theme.tertiary).lineLimit(1).fixedSize()
                }
            }
            CIRow(status: status)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                syncButton(title: status.behind > 0 ? "Pull \(status.behind)" : "Pull", icon: "arrow.down", job: "pull",
                           prominent: status.behind > 0) { git.pull() }
                syncButton(title: status.upstream == nil ? "Publish" : (status.ahead > 0 ? "Push \(status.ahead)" : "Push"),
                           icon: "arrow.up", job: "push", prominent: status.ahead > 0 || (status.upstream == nil && status.lastCommit != nil)) { git.push() }
                Spacer()
                IconButton(systemName: "terminal.fill", size: 11, frame: 26, filled: true, help: "Открыть в терминале") { git.openInTerminal() }
                if status.webURL != nil {
                    IconButton(systemName: "safari.fill", size: 11, frame: 26, filled: true, help: git.ci.url != nil ? "Открыть PR / CI" : "Открыть на сайте") { git.openWeb() }
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .card(radius: 18)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(git.recent, id: \.self) { root in
                    Button {
                        git.select(root)
                    } label: {
                        Label((root as NSString).lastPathComponent, systemImage: root == status.root ? "checkmark" : "folder")
                    }
                }
                Divider()
                Button("Выбрать папку…") { GitSettings.chooseFolder() }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: status.root)]) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(Theme.git)
                    Text(status.name).font(Theme.font(14, .bold)).foregroundStyle(.white).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(status.root)

            Spacer()
            if git.pinned {
                Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                    .help("Выбран вручную — переключится, когда вы откроете другой терминал или редактор")
            } else {
                Text("авто").font(Theme.font(9, .bold)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 5).frame(height: 14).background(Capsule().fill(Theme.surface))
                    .help("Репозиторий определяется по активному терминалу или редактору")
            }
        }
    }

    private var branchRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: status.detached ? "exclamationmark.triangle.fill" : "arrow.triangle.branch").font(.system(size: 10, weight: .bold))
                Text(status.branch.isEmpty ? "…" : status.branch).font(Theme.font(12, .semibold)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(status.detached ? Color.orange : .white)
            .padding(.horizontal, 8).frame(height: 22)
            .background(Capsule().fill(Theme.git.opacity(0.18)))
            .contentTransition(.opacity)
            .onTapGesture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(status.branch, forType: .string)
            }
            .help("Скопировать название ветки")

            if status.ahead > 0 { syncBadge("arrow.up", status.ahead, .green) }
            if status.behind > 0 { syncBadge("arrow.down", status.behind, .orange) }
            if status.upstream == nil, !status.detached, !status.branch.isEmpty {
                Text("не опубликована").font(Theme.font(10)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func syncBadge(_ icon: String, _ n: Int, _ tint: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .heavy))
            Text("\(n)").font(Theme.font(11, .bold)).monospacedDigit()
        }
        .foregroundStyle(tint)
        .transition(.scale.combined(with: .opacity))
    }

    private var counters: some View {
        HStack(spacing: 5) {
            if status.isClean {
                counter("checkmark", "чисто", .green)
            } else {
                if status.conflicts > 0 { counter("exclamationmark.2", "\(status.conflicts) конфл.", .red) }
                if status.staged > 0 { counter("tray.and.arrow.down.fill", "\(status.staged) в индексе", .green) }
                if status.modified > 0 { counter("pencil", "\(status.modified) изм.", .orange) }
                if status.untracked > 0 { counter("plus", "\(status.untracked) нов.", Theme.secondary) }
            }
            Spacer(minLength: 0)
        }
    }

    private func counter(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold))
            Text(text).font(Theme.font(10, .semibold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).frame(height: 18)
        .background(Capsule().fill(tint.opacity(0.13)))
    }

    private func syncButton(title: String, icon: String, job: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if git.busy == job {
                    ProgressView().controlSize(.mini).tint(prominent ? .black : .white)
                } else {
                    Image(systemName: icon).font(.system(size: 10, weight: .bold))
                }
                Text(title).font(Theme.font(11, .semibold))
            }
            .foregroundStyle(prominent ? Color.black : .white)
            .padding(.horizontal, 10).frame(height: 26)
            .background(Capsule().fill(prominent ? Theme.git : Theme.surfaceHover))
        }
        .buttonStyle(PressableStyle())
        .disabled(git.busy != nil)
    }
}

/// PR and checks: a spinning ring while CI runs, then green or red.
private struct CIRow: View {
    let status: GitStatus
    @EnvironmentObject var git: GitService
    @EnvironmentObject var settings: Settings

    var body: some View {
        let ci = git.ci
        HStack(spacing: 6) {
            if !settings.gitCIEnabled || !status.isGitHub {
                EmptyView()
            } else if !git.ghAvailable {
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                Text("Для CI и PR установите GitHub CLI (brew install gh)").font(Theme.font(10)).foregroundStyle(Theme.tertiary).lineLimit(1)
            } else if ci.state == .none && ci.prNumber == nil {
                Image(systemName: "circle.dashed").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                Text("Нет PR и запусков CI").font(Theme.font(10)).foregroundStyle(Theme.tertiary)
            } else {
                indicator(ci.state)
                VStack(alignment: .leading, spacing: 0) {
                    Text(ci.prNumber.map { "PR #\($0) · \(ci.title)" } ?? ci.title)
                        .font(Theme.font(11, .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(caption(ci)).font(Theme.font(10)).foregroundStyle(color(ci.state).opacity(0.9)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let review = ci.review { reviewBadge(review) }
            }
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .onTapGesture { git.openWeb() }
    }

    @ViewBuilder private func indicator(_ state: GitCI.State) -> some View {
        ZStack {
            Circle().fill(color(state).opacity(0.16)).frame(width: 22, height: 22)
            if state == .pending {
                TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate * 300))
                }
            } else {
                Image(systemName: state == .success ? "checkmark" : (state == .failure ? "xmark" : "minus"))
                    .font(.system(size: 10, weight: .heavy)).foregroundStyle(color(state))
            }
        }
        .transition(.scale.combined(with: .opacity))
    }

    private func caption(_ ci: GitCI) -> String {
        switch ci.state {
        case .pending: return ci.checksTotal > 1 ? "проверки идут · \(ci.checksDone)/\(ci.checksTotal)" : "CI идёт…"
        case .success: return ci.checksTotal > 1 ? "все проверки прошли · \(ci.checksTotal)" : "CI прошёл"
        case .failure: return "упало: \(ci.failedCheck ?? "проверка")"
        case .none: return "без проверок"
        }
    }

    private func color(_ state: GitCI.State) -> Color {
        switch state {
        case .pending: return .yellow
        case .success: return .green
        case .failure: return .red
        case .none: return Theme.secondary
        }
    }

    private func reviewBadge(_ review: String) -> some View {
        let (icon, tint, help): (String, Color, String) = switch review {
        case "APPROVED": ("hand.thumbsup.fill", .green, "Одобрено")
        case "CHANGES_REQUESTED": ("text.bubble.fill", .orange, "Просят правки")
        default: ("eye.fill", Theme.secondary, "Ждёт ревью")
        }
        return Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint).help(help)
    }
}

// MARK: - Changes and commit

private struct ChangesCard: View {
    let status: GitStatus
    @EnvironmentObject var git: GitService
    @EnvironmentObject var ai: AIChatService
    @EnvironmentObject var vm: NotchViewModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status.isClean {
                clean
            } else {
                HStack {
                    Text("Изменения").font(Theme.font(13, .bold)).foregroundStyle(.white)
                    Text("\(Set(status.files.map(\.path)).count)").font(Theme.font(10, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 6).frame(height: 16).background(Capsule().fill(Theme.git))
                    Spacer()
                }
                fileList
                composer
            }
            feedback
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(radius: 18)
        .onChange(of: focused) { _, f in vm.isTyping = f }
    }

    private var clean: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 24)).foregroundStyle(Theme.git)
            Text("Всё закоммичено").font(Theme.font(13, .semibold)).foregroundStyle(.white)
            Text(status.ahead > 0 ? "Осталось отправить \(status.ahead) коммит(ов)" : "Рабочая копия чистая")
                .font(Theme.font(11)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(status.files.prefix(60)) { f in
                    HStack(spacing: 6) {
                        Text(letter(f)).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(tint(f)).frame(width: 12)
                        Text((f.path as NSString).lastPathComponent).font(Theme.font(11, .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        Text((f.path as NSString).deletingLastPathComponent).font(Theme.font(10)).foregroundStyle(Theme.tertiary)
                            .lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 17)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: status.root).appendingPathComponent(f.path)) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextField("", text: $git.commitMessage, prompt: Text(status.staged > 0 ? "Сообщение коммита…" : "Сообщение — закоммичу все изменения…").foregroundStyle(Theme.tertiary), axis: .vertical)
                    .textFieldStyle(.plain).font(Theme.font(12)).foregroundStyle(.white)
                    .lineLimit(1...3)
                    .focused($focused)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .opacity(git.generating && git.commitMessage.isEmpty ? 0 : 1)
                if git.generating && git.commitMessage.isEmpty {
                    ShimmerText(text: "ИИ читает diff…").padding(.horizontal, 9).padding(.vertical, 6)
                }
            }
            .card(radius: 12, fill: Color.white.opacity(focused ? 0.1 : 0.06))

            HStack(spacing: 6) {
                Button { git.generateMessage() } label: {
                    HStack(spacing: 4) {
                        if git.generating {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                        }
                        Text(git.commitMessage.isEmpty ? "Написать с ИИ" : "Ещё вариант").font(Theme.font(11, .semibold))
                    }
                    .foregroundStyle(ai.provider.tint)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(ai.provider.tint.opacity(0.15)))
                }
                .buttonStyle(PressableStyle())
                .disabled(git.generating)
                .help("Сгенерировать сообщение по diff (\(ai.provider.title))")

                Spacer()

                Button { git.commit() } label: {
                    HStack(spacing: 4) {
                        if git.busy == "commit" {
                            ProgressView().controlSize(.mini).tint(.black)
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                        }
                        Text(status.staged > 0 ? "Коммит \(status.staged)" : "Коммит всего").font(Theme.font(11, .bold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(Capsule().fill(canCommit ? Theme.git : Color.white.opacity(0.25)))
                }
                .buttonStyle(PressableStyle())
                .disabled(!canCommit)
                .help(status.staged > 0 ? "Закоммитить файлы из индекса" : "git add -A и коммит")
            }
        }
    }

    private var canCommit: Bool {
        git.busy == nil && status.conflicts == 0 && !git.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var feedback: some View {
        if let error = git.lastError {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                Text(error).font(Theme.font(10)).lineLimit(2)
            }
            .foregroundStyle(.red.opacity(0.9))
            .onTapGesture { git.lastError = nil }
        } else if let result = git.lastResult {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                Text(result).font(Theme.font(10, .semibold)).lineLimit(1)
            }
            .foregroundStyle(.green)
        }
    }

    private func letter(_ f: GitFile) -> String {
        switch f.kind {
        case .untracked: return "U"
        case .conflict: return "!"
        case .staged: return String(f.code.prefix(1))
        case .modified: return String(f.code.suffix(1))
        }
    }

    private func tint(_ f: GitFile) -> Color {
        switch f.kind {
        case .staged: return .green
        case .modified: return f.code.hasSuffix("D") ? .red : .orange
        case .untracked: return Theme.secondary
        case .conflict: return .red
        }
    }
}

/// Placeholder text with a light sweeping across it.
private struct ShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            Text(text).font(Theme.font(12)).foregroundStyle(Theme.tertiary)
                .overlay {
                    LinearGradient(colors: [.clear, .white.opacity(0.9), .clear],
                                   startPoint: UnitPoint(x: phase * 2 - 0.6, y: 0.5), endPoint: UnitPoint(x: phase * 2 - 0.1, y: 0.5))
                        .mask(Text(text).font(Theme.font(12)))
                }
        }
    }
}

// MARK: - Settings

struct GitSettings: View {
    @ObservedObject var settings = Settings.shared
    @ObservedObject var git = AppEnvironment.shared.git

    var body: some View {
        Form {
            Section("Git в вырезе") {
                Toggle("Вкладка Git", isOn: $settings.gitEnabled)
                Text("Репозиторий определяется по активному терминалу (вкладка, в которой вы печатали последней), редактору или агенту — без дополнительных разрешений.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("GitHub") {
                Toggle("Статус CI и PR, реакции мордочки", isOn: $settings.gitCIEnabled)
                    .disabled(!settings.gitEnabled)
                LabeledContent("GitHub CLI") {
                    Text(git.ghAvailable ? "найден" : "не найден — brew install gh, затем gh auth login")
                        .foregroundStyle(git.ghAvailable ? .green : .secondary)
                }
            }
            Section("Недавние репозитории") {
                if git.recent.isEmpty {
                    Text("Пока нет").foregroundStyle(.secondary)
                }
                ForEach(git.recent, id: \.self) { root in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((root as NSString).lastPathComponent)
                            Text(root).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { git.forget(root) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Добавить папку…") { Self.chooseFolder() }
            }
            Section {
                Text("Сообщения коммитов пишет выбранный в настройках ИИ: ему уходит diff изменений.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @MainActor static func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Выбрать"
        panel.message = "Папка с git-репозиторием"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let root = RepoDetector.gitRoot(url.path) {
            AppEnvironment.shared.git.select(root)
        } else {
            let alert = NSAlert()
            alert.messageText = "Это не git-репозиторий"
            alert.informativeText = url.path
            alert.runModal()
        }
    }
}
