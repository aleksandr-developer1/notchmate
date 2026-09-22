import SwiftUI

extension Theme {
    static let jira = Color(red: 0.30, green: 0.58, blue: 1.0)
}

struct JiraView: View {
    @EnvironmentObject var jira: JiraService
    @EnvironmentObject var settings: Settings

    var body: some View {
        if !jira.isConfigured {
            setupPrompt
        } else {
            HStack(alignment: .top, spacing: 10) {
                ActiveIssueCard().frame(width: 318)
                IssueList()
            }
            .onAppear { if (jira.lastUpdated.map { Date().timeIntervalSince($0) > 60 } ?? true) { jira.refresh() } }
        }
    }

    private var setupPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "briefcase.fill").font(.system(size: 30)).foregroundStyle(Theme.jira)
            Text(String(localized: "Подключите Jira")).font(Theme.font(15, .bold)).foregroundStyle(.white)
            Text(String(localized: "Нужен адрес и Personal Access Token — задачи, эстимейты и списание времени появятся здесь"))
                .font(Theme.font(12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            PillButton(title: String(localized: "Открыть настройки Jira"), icon: "gearshape.fill", tint: Theme.jira, prominent: true) {
                NotificationCenter.default.post(name: .notchMateOpenSettings, object: nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 18)
    }
}

private struct ActiveIssueCard: View {
    @EnvironmentObject var jira: JiraService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let issue = jira.activeIssue {
                content(issue)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "hand.point.right.fill").font(.system(size: 22)).foregroundStyle(Theme.tertiary)
                    Text(jira.issues.isEmpty ? (jira.isLoading ? String(localized: "Загружаю задачи…") : String(localized: "Задач нет")) : String(localized: "Выберите задачу справа"))
                        .font(Theme.font(12)).foregroundStyle(Theme.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .card(radius: 18)
    }

    @ViewBuilder private func content(_ issue: JiraIssue) -> some View {
        HStack(spacing: 6) {
            Text(issue.isWorking ? String(localized: "В РАБОТЕ") : String(localized: "ВЫБРАНА")).font(Theme.font(9, .heavy)).foregroundStyle(Theme.jira)
            Button { jira.open(issue) } label: {
                HStack(spacing: 3) {
                    Text(issue.key).font(Theme.font(11, .bold))
                    Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .bold))
                }.foregroundStyle(.white.opacity(0.85))
            }.buttonStyle(.plain).help(String(localized: "Открыть в Jira"))
            Spacer()
            StatusPill(issue: issue)
        }
        Text(issue.summary).font(Theme.font(14, .semibold)).foregroundStyle(.white).lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let session = jira.sessionKey == issue.key ? Int(jira.sessionElapsed(at: ctx.date)) : 0
            let logged = issue.timeSpent ?? 0
            // Time in work from the status history; fall back to logged time + local session.
            let spent = issue.progressPeriods.isEmpty ? logged + session : issue.timeInWork(at: ctx.date)
            let original = issue.originalEstimate
            let remaining: Int? = original.map { $0 - spent } ?? issue.remainingEstimate.map { $0 - session }
            let total = max(original ?? (spent + max(remaining ?? 0, 0)), 1)
            let over = (remaining ?? 1) < 0
            VStack(alignment: .leading, spacing: 8) {
                EstimateBar(spent: Double(spent) / Double(total),
                            logged: Double(logged) / Double(total), over: over)
                HStack(spacing: 0) {
                    stat(String(localized: "Прошло"), JiraService.format(spent), .white)
                    stat(String(localized: "Осталось"), JiraService.format(remaining), over ? .red : Theme.jira)
                    stat(String(localized: "Оценка"), JiraService.format(original), Theme.secondary)
                }
                HStack(spacing: 4) {
                    if let since = issue.inProgressSince {
                        Text(String(localized: "В работе с \(since.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(AppLanguage.locale)))"))
                    }
                    if logged > 0 { Text(String(localized: "· списано \(JiraService.format(logged))")) }
                }
                .font(Theme.font(10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                sessionControls(issue, session: session)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.font(15, .bold)).monospacedDigit().foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label).font(Theme.font(10)).foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func sessionControls(_ issue: JiraIssue, session: Int) -> some View {
        let mine = jira.sessionKey == issue.key
        let busyElsewhere = !jira.sessionIsIdle && !mine
        HStack(spacing: 8) {
            Button { jira.toggleTracking(issue) } label: {
                HStack(spacing: 6) {
                    Image(systemName: jira.isTracking && mine ? "pause.fill" : "play.fill").font(.system(size: 11, weight: .bold))
                    Text(mine && session > 0 ? FocusTimer.format(TimeInterval(session)) : String(localized: "Начать таймер"))
                        .font(Theme.font(12, .bold)).monospacedDigit()
                }
                .foregroundStyle(.black).padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(jira.isTracking && mine ? Color.orange : Theme.jira))
            }
            .buttonStyle(PressableStyle())
            .disabled(busyElsewhere)
            .help(busyElsewhere ? String(localized: "Сначала завершите таймер по \(jira.sessionKey ?? "")") : String(localized: "Таймер работы над задачей"))

            if mine && session >= 60 {
                PillButton(title: String(localized: "Списать \(JiraService.format(session))"), icon: "arrow.up.doc.fill", tint: .green) {
                    Task { await jira.logSession() }
                }
                .help(String(localized: "Создать worklog в Jira — остаток эстимейта уменьшится"))
            }
            if mine && !jira.sessionIsIdle {
                IconButton(systemName: "xmark", size: 10, frame: 26, tint: Theme.secondary, help: String(localized: "Сбросить таймер без списания")) {
                    jira.discardSession()
                }
            }
            Spacer(minLength: 0)
        }
        if let msg = jira.lastLogMessage {
            Text(msg.text).font(Theme.font(10, .medium)).foregroundStyle(msg.ok ? .green : .orange).lineLimit(1)
        }
    }
}

private struct EstimateBar: View {
    let spent: Double     // logged + session, 0...1 of total
    let logged: Double
    let over: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill((over ? Color.red : Theme.jira).opacity(0.45))
                    .frame(width: geo.size.width * min(spent, 1))
                Capsule().fill(over ? Color.red : Theme.jira)
                    .frame(width: max(0, geo.size.width * min(logged, 1)))
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.4), value: spent)
    }
}

private struct StatusPill: View {
    let issue: JiraIssue
    var body: some View {
        Text(issue.status).font(Theme.font(9, .bold)).lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }
    private var color: Color {
        switch issue.statusCategory {
        case "indeterminate": return Theme.jira
        case "done": return .green
        default: return Color(white: 0.75)
        }
    }
}

private struct IssueList: View {
    @EnvironmentObject var jira: JiraService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(localized: "Мои задачи")).font(Theme.font(13, .bold)).foregroundStyle(.white)
                Text("\(jira.issues.count)").font(Theme.font(11, .semibold)).foregroundStyle(Theme.tertiary)
                Spacer()
                if jira.isLoading { ProgressView().controlSize(.mini) }
                IconButton(systemName: "arrow.clockwise", size: 10, frame: 24, help: String(localized: "Обновить")) { jira.refresh() }
            }
            if let err = jira.error {
                Text(err).font(Theme.font(11)).foregroundStyle(.orange).lineLimit(2)
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(jira.issues) { issue in row(issue) }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity, alignment: .top)
        .card(radius: 18)
    }

    private func row(_ issue: JiraIssue) -> some View {
        HoverRow(selected: jira.activeIssue?.key == issue.key, radius: 8) {
            HStack(spacing: 8) {
                Circle().fill(issue.isWorking ? Theme.jira : (issue.isInProgress ? Color.orange.opacity(0.7) : Color.white.opacity(0.25))).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(issue.summary).font(Theme.font(12)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(issue.key).font(Theme.font(10, .semibold)).foregroundStyle(Theme.secondary)
                        Text(issue.status).font(Theme.font(10)).foregroundStyle(Theme.tertiary)
                    }.lineLimit(1)
                }
                Spacer(minLength: 4)
                if let rem = issue.originalEstimate.map({ $0 - issue.timeInWork() }) ?? issue.remainingEstimate {
                    Text(JiraService.format(rem)).font(Theme.font(10, .semibold)).monospacedDigit()
                        .foregroundStyle(rem <= 0 && (issue.timeSpent ?? 0) > 0 ? .red : Theme.secondary)
                }
                if jira.sessionKey == issue.key {
                    Image(systemName: jira.isTracking ? "record.circle" : "pause.circle").font(.system(size: 11))
                        .foregroundStyle(.orange).symbolEffect(.pulse, isActive: jira.isTracking)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
        }
        .onTapGesture(count: 2) { jira.open(issue) }
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { jira.select(issue) } }
        .contextMenu {
            Button(String(localized: "Сделать активной")) { jira.select(issue) }
            Button(String(localized: "Открыть в Jira")) { jira.open(issue) }
            Button(String(localized: "Копировать ключ")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(issue.key, forType: .string)
            }
            Button(String(localized: "Копировать «\(issue.key) \(issue.summary)»")) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(issue.key) \(issue.summary)", forType: .string)
            }
        }
    }
}
