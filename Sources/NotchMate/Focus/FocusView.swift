import SwiftUI

struct FocusView: View {
    @EnvironmentObject var focus: FocusTimer
    @EnvironmentObject var jira: JiraService
    @EnvironmentObject var distractions: DistractionGuard
    @ObservedObject var settings = Settings.shared

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Ring(progress: focus.isActive || focus.phase == .finished ? focus.progress : 0, tint: tint, lineWidth: 7)
                    .shadow(color: tint.opacity(0.5), radius: focus.phase == .running ? 10 : 0)
                    .animation(.linear(duration: 0.25), value: focus.progress)
                VStack(spacing: 2) {
                    Text(FocusTimer.format(focus.phase == .idle ? settings.pomoWork * 60 : focus.remaining))
                        .font(Theme.font(28, .bold)).monospacedDigit().foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.default, value: Int(focus.remaining))
                    Text(statusText).font(Theme.font(11, .medium)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 140, height: 140)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(focus.phase == .idle ? String(localized: "Помидоро") : focus.kind.title).font(Theme.font(17, .bold)).foregroundStyle(.white)
                    cycleDots
                }
                if focus.kind == .work, focus.phase != .idle {
                    Text(focus.label).font(Theme.font(12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }

                HStack(spacing: 8) { controls }

                HStack(spacing: 10) {
                    Label(String(localized: "\(Int(settings.pomoWork))/\(Int(settings.pomoShort))/\(Int(settings.pomoLong)) мин"), systemImage: "slider.horizontal.3")
                    if distractions.sessionCount > 0 {
                        Label(String(localized: "отвлечений: \(distractions.sessionCount)"), systemImage: "eye.trianglebadge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }
                .font(Theme.font(10)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 20)
    }

    private var cycleDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<focus.cycleLength, id: \.self) { i in
                Circle()
                    .fill(i < focus.completedInCycle % max(focus.cycleLength, 1) || (focus.completedInCycle > 0 && focus.completedInCycle % focus.cycleLength == 0 && focus.kind.isBreak) ? Color.orange : Color.white.opacity(0.15))
                    .frame(width: 7, height: 7)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch focus.phase {
        case .idle:
            PillButton(title: String(localized: "Старт \(Int(settings.pomoWork)) мин"), icon: "play.fill", tint: .orange, prominent: true) {
                if let issue = jira.activeIssue {
                    focus.start(label: "\(issue.key) · \(issue.summary)", task: issue.key)
                } else {
                    focus.start(label: String(localized: "Помидор"))
                }
            }
        case .running, .paused:
            PillButton(title: focus.phase == .running ? String(localized: "Пауза") : String(localized: "Продолжить"),
                       icon: focus.phase == .running ? "pause.fill" : "play.fill", tint: tint, prominent: true) { focus.toggle() }
            if focus.kind.isBreak {
                PillButton(title: String(localized: "К работе"), icon: "forward.fill") { focus.skipBreak() }
            } else {
                PillButton(title: String(localized: "+5 мин"), icon: "plus") { focus.add(minutes: 5) }
            }
            PillButton(title: String(localized: "Сброс"), icon: "arrow.counterclockwise") { withAnimation { focus.reset() } }
        case .finished:
            if focus.kind == .work {
                PillButton(title: focus.nextBreakTitle, icon: "cup.and.saucer.fill", tint: .green, prominent: true) { focus.startBreak() }
                PillButton(title: String(localized: "Ещё фокус"), icon: "play.fill") { focus.start(label: focus.label) }
            } else {
                PillButton(title: String(localized: "К работе"), icon: "play.fill", tint: .orange, prominent: true) { focus.start(label: focus.label) }
            }
            PillButton(title: String(localized: "Стоп"), icon: "stop.fill") { withAnimation { focus.reset() } }
        }
    }

    private var tint: Color { focus.kind.isBreak ? .green : .orange }

    private var statusText: String {
        switch focus.phase {
        case .idle: return String(localized: "готов")
        case .running: return focus.kind.isBreak ? String(localized: "отдыхаем") : String(localized: "идёт")
        case .paused: return String(localized: "пауза")
        case .finished: return focus.kind == .work ? String(localized: "готово!") : String(localized: "перерыв окончен")
        }
    }
}

extension FocusTimer {
    var nextBreakTitle: String {
        let long = completedInCycle % cycleLength == 0 && completedInCycle > 0
        return long ? String(localized: "Длинный перерыв") : String(localized: "Перерыв")
    }
}
