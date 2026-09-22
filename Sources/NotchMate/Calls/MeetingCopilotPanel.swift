import AppKit
import SwiftUI

/// Floating hints under the notch. Hidden from screen sharing and recordings: the other side never sees it.
@MainActor
final class MeetingCopilotPanelController {
    private let panel: NotchPanel
    private let copilot: MeetingCopilot
    private let width: CGFloat = 440

    init(env: AppEnvironment) {
        copilot = env.copilot
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                           styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        let root = MeetingCopilotView(onHeight: { [weak self] h in self?.resize(to: h) })
            .environmentObject(env.copilot)
            .environmentObject(env.git)
            .environmentObject(env.calls)
        let hosting = NotchHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        copilot.onVisibilityChanged = { [weak self] visible in
            guard let self else { return }
            if visible {
                self.panel.sharingType = Settings.shared.meetingHideFromCapture ? .none : .readOnly
                if !self.panel.isVisible { self.place() }
                self.panel.orderFrontRegardless()
            } else {
                self.panel.orderOut(nil)
            }
        }
    }

    /// Top-centre, just below the notch / menu bar.
    private func place() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let top = screen.visibleFrame.maxY - 8
        let height = panel.frame.height
        panel.setFrame(NSRect(x: screen.frame.midX - width / 2, y: top - height, width: width, height: height), display: true)
    }

    /// Grows downward with the content, keeping the top edge where the user left it.
    private func resize(to height: CGFloat) {
        let h = ceil(height)
        guard abs(panel.frame.height - h) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - h
        frame.size.height = h
        panel.setFrame(frame, display: true, animate: false)
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct MeetingCopilotView: View {
    var onHeight: (CGFloat) -> Void
    @EnvironmentObject var copilot: MeetingCopilot
    @EnvironmentObject var git: GitService
    @EnvironmentObject var calls: CallRecorder
    @FocusState private var inputFocused: Bool

    private let accent = Color(red: 0.62, green: 0.55, blue: 1.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if !copilot.transcriptTail.isEmpty {
                Text(copilot.transcriptTail)
                    .font(Theme.font(10.5)).foregroundStyle(Theme.tertiary)
                    .lineLimit(2).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = copilot.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.font(11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if copilot.hints.isEmpty {
                Text(copilot.isListening
                     ? String(localized: "Слушаю разговор — подсказки появятся сами на паузах. ⌃⌥H — подсказать сейчас.")
                     : String(localized: "Запускаю запись и расшифровку…"))
                    .font(Theme.font(12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(copilot.hints) { hint in
                            HintCard(hint: hint, isLatest: hint.id == copilot.hints.first?.id)
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            input
        }
        .padding(14)
        .frame(width: 440, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke))
        )
        .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        .onPreferenceChange(HeightKey.self) { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: copilot.hints)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(accent)
            Text(String(localized: "Помощник")).font(Theme.font(13, .semibold)).foregroundStyle(.white)
            status
            Spacer(minLength: 4)
            modelMenu
            repoMenu
            Button { copilot.clear() } label: {
                Image(systemName: "trash").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(PressableStyle()).help(String(localized: "Очистить подсказки"))
            .opacity(copilot.hints.isEmpty ? 0 : 1)
            Button { copilot.close() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.secondary)
            }
            .buttonStyle(PressableStyle()).help(String(localized: "Выключить помощника (запись созвона продолжится)"))
        }
    }

    @ViewBuilder private var status: some View {
        if copilot.isThinking {
            ProgressView().controlSize(.mini).tint(accent)
        } else if copilot.isListening {
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(FocusTimer.format(calls.elapsed)).font(Theme.font(10, .bold)).monospacedDigit().foregroundStyle(Theme.secondary)
                }
            }
        } else if !copilot.hints.isEmpty {
            Text(String(localized: "встреча закончилась")).font(Theme.font(10)).foregroundStyle(Theme.tertiary)
        }
    }

    private var modelMenu: some View {
        Menu {
            Button(String(localized: "Самая быстрая из доступных")) { copilot.chooseModel("") }
            Divider()
            ForEach(copilot.fastModels) { m in
                Button(m.available ? m.title : "\(m.title) — \(m.note)") { copilot.chooseModel(m.id) }
                    .disabled(!m.available)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                Text(copilot.currentModel.map { $0.model } ?? String(localized: "нет модели")).font(Theme.font(10.5, .semibold)).lineLimit(1)
            }
            .foregroundStyle(copilot.currentModel == nil ? Color.orange : Theme.secondary)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Capsule().fill(Theme.surface))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "Модель для подсказок — только быстрые"))
    }

    private var repoMenu: some View {
        Menu {
            let options = ([copilot.repoRoot, git.status?.root].compactMap { $0 } + git.recent).reduce(into: [String]()) { list, r in
                if !list.contains(r) { list.append(r) }
            }
            ForEach(options, id: \.self) { root in
                Button((root as NSString).lastPathComponent) { copilot.chooseRepo(root) }
            }
            Divider()
            Button(String(localized: "Выбрать папку…")) {
                let open = NSOpenPanel()
                open.canChooseDirectories = true
                open.canChooseFiles = false
                if open.runModal() == .OK, let url = open.url { copilot.chooseRepo(RepoDetector.gitRoot(url.path) ?? url.path) }
            }
            Button(String(localized: "Без кода")) { copilot.chooseRepo(nil) }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 9, weight: .bold))
                Text(copilot.repoRoot.map { ($0 as NSString).lastPathComponent } ?? String(localized: "без кода")).font(Theme.font(10.5, .semibold)).lineLimit(1)
            }
            .foregroundStyle(copilot.repoRoot == nil ? Theme.tertiary : Theme.secondary)
            .padding(.horizontal, 7).frame(height: 20)
            .background(Capsule().fill(Theme.surface))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "По какому проекту подсказывать"))
    }

    private var input: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Спросить: что ответить про сроки?"), text: $copilot.draft)
                .textFieldStyle(.plain).font(Theme.font(12)).foregroundStyle(.white)
                .focused($inputFocused)
                .onSubmit { copilot.ask() }
                .padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.surface))
            Button { copilot.draft.isEmpty ? copilot.hintNow() : copilot.ask() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "sparkles").font(.system(size: 10, weight: .bold))
                    Text(String(localized: "Подсказать")).font(Theme.font(11, .bold))
                }
                .foregroundStyle(.black).padding(.horizontal, 10).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(accent))
            }
            .buttonStyle(PressableStyle()).help("⌃⌥H")
        }
    }
}

private struct HintCard: View {
    let hint: MeetingCopilot.Hint
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let q = hint.question {
                Text("«\(q)»").font(Theme.font(10.5, .medium)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            if hint.isError {
                Text(hint.text).font(Theme.font(11.5)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if hint.lines.isEmpty {
                Text(hint.isStreaming ? String(localized: "Думаю…") : String(localized: "Добавить нечего")).font(Theme.font(11.5)).foregroundStyle(Theme.tertiary)
            } else {
                ForEach(hint.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: icon(line.kind)).font(.system(size: 10, weight: .bold)).foregroundStyle(tint(line.kind))
                            .frame(width: 14)
                        Text(line.text).font(Theme.font(isLatest ? 13 : 11.5, isLatest ? .medium : .regular))
                            .foregroundStyle(isLatest ? Color.white : Theme.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isLatest ? Theme.surfaceHover : Theme.surface))
    }

    private func icon(_ kind: MeetingCopilot.Hint.Kind) -> String {
        switch kind {
        case .option: return "arrow.triangle.branch"
        case .ask: return "questionmark.bubble.fill"
        case .say: return "text.bubble.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .risk: return "exclamationmark.triangle.fill"
        case .plain: return "sparkle"
        }
    }

    private func tint(_ kind: MeetingCopilot.Hint.Kind) -> Color {
        switch kind {
        case .option: return Color(red: 0.35, green: 0.85, blue: 0.85)
        case .ask: return Color(red: 0.45, green: 0.72, blue: 1.0)
        case .say: return Color(red: 0.4, green: 0.85, blue: 0.55)
        case .code: return Color(red: 0.75, green: 0.6, blue: 1.0)
        case .risk: return .orange
        case .plain: return Theme.secondary
        }
    }
}
