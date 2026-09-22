import AppKit
import SwiftUI

struct AttentionItem: Identifiable, Equatable {
    enum Action: Equatable { case openAgent(AgentKind, host: String?), joinMeeting(String), openJira(String), openNote(String), startBreak, meetingAssistant, stopCall, startCall, processCalls, openGit, completeReminder(String), none }

    let id: String
    let icon: String
    let appIcon: NSImage?
    let tint: Color
    let title: String
    let subtitle: String
    let actionTitle: String?
    let action: Action
    let dismissable: Bool
    let priority: Int

    static func == (a: AttentionItem, b: AttentionItem) -> Bool {
        a.id == b.id && a.title == b.title && a.subtitle == b.subtitle
    }
}

/// Things that are waiting on the user: agents, meetings, estimates, new Jira issues, finished runs.
@MainActor
final class AttentionCenter: ObservableObject {
    private struct Finished {
        let agent: AgentKind; let project: String; let duration: Int; let at: Date; let host: String?

        /// Switching to the app the agent ran in means the user has seen the result.
        func isSeen(in bundleID: String?) -> Bool {
            guard let bundleID else { return false }
            if let host { return host == bundleID || agent.appBundleIDs.contains(bundleID) }
            return agent.appBundleIDs.contains(bundleID) || RepoDetector.isDevApp(bundleID)
        }
    }

    @Published private var dismissed: Set<String> = []
    @Published private var finished: [String: Finished] = [:]
    @Published private var newIssues: [String] = []
    @Published private var ciFailures: [String: (repo: String, ci: GitCI)] = [:]

    private weak var env: AppEnvironment?
    private let seenKey = "attentionSeenJiraKeys"

    func start(env: AppEnvironment) {
        self.env = env
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.appActivated(bundleID) }
        }
    }

    private func appActivated(_ bundleID: String?) {
        let seen = finished.filter { $0.value.isSeen(in: bundleID) }.map(\.key)
        guard !seen.isEmpty else { return }
        withAnimation(.spring(response: 0.3)) { seen.forEach { finished.removeValue(forKey: $0) } }
    }

    // MARK: Inputs

    func agentFinished(_ s: AgentSession) {
        let seconds = Int(Date().timeIntervalSince(s.startedAt))
        guard seconds >= 60 else { return }
        let item = Finished(agent: s.agent, project: s.project, duration: seconds, at: Date(), host: s.hostBundleID)
        // Already looking at it — nothing to remind about.
        if item.isSeen(in: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) { return }
        // One entry per session: a newer finish replaces the older one instead of piling up.
        finished = finished.filter { !$0.key.hasPrefix("finished-\(s.id)-") }
        finished["finished-\(s.id)-\(Int(Date().timeIntervalSince1970))"] = item
    }

    /// Called after each Jira refresh: issues not seen before are "newly assigned".
    func jiraUpdated(keys: [String]) {
        let defaults = UserDefaults.standard
        guard let seen = defaults.stringArray(forKey: seenKey) else {
            defaults.set(keys, forKey: seenKey)   // first run: don't flood with everything
            return
        }
        let fresh = keys.filter { !seen.contains($0) }
        if !fresh.isEmpty {
            newIssues.append(contentsOf: fresh.filter { !newIssues.contains($0) })
            defaults.set(Array(Set(seen + keys)), forKey: seenKey)
        }
    }

    func gitCIFailed(repo: String, ci: GitCI) {
        let id = "ci-\(repo)-\(ci.prNumber.map(String.init) ?? ci.title)"
        withAnimation(.spring(response: 0.3)) {
            dismissed.remove(id)
            ciFailures[id] = (repo, ci)
        }
    }

    func dismiss(_ item: AttentionItem) {
        // A meeting the user swiped away should disappear from the whole app —
        // notch, chat prompts and this list — not just until the next refresh.
        if item.id.hasPrefix("meet-"), let env,
           let event = env.calendar.events.first(where: { "meet-\($0.id)" == item.id }) {
            env.calendar.hide(event)
        }
        withAnimation(.spring(response: 0.3)) {
            dismissed.insert(item.id)
            finished.removeValue(forKey: item.id)
            ciFailures.removeValue(forKey: item.id)
            if item.id.hasPrefix("new-") { newIssues.removeAll { "new-\($0)" == item.id } }
        }
    }

    // MARK: Items

    var items: [AttentionItem] {
        guard let env else { return [] }
        var out: [AttentionItem] = []
        let now = Date()

        for s in env.agents.sessions.values where s.state == .waiting {
            out.append(AttentionItem(id: "wait-\(s.id)", icon: s.agent.fallbackSymbol, appIcon: s.agent.icon, tint: .orange,
                                     title: String(localized: "\(s.agent.title) ждёт ответа"), subtitle: "\(s.project) · \(Self.ago(s.updatedAt))",
                                     actionTitle: String(localized: "Перейти"), action: .openAgent(s.agent, host: s.hostBundleID), dismissable: false, priority: 100))
        }

        if let e = env.calendar.next, e.start.timeIntervalSinceNow < 15 * 60, e.end > now {
            let when = e.isNow ? String(localized: "идёт сейчас") : String(localized: "через \(max(e.minutesUntil, 1)) мин")
            out.append(AttentionItem(id: "meet-\(e.id)", icon: "calendar", appIcon: nil, tint: e.color,
                                     title: e.title, subtitle: when,
                                     actionTitle: e.meetingURL != nil ? String(localized: "Подключиться") : nil,
                                     action: e.meetingURL != nil ? .joinMeeting(e.id) : .none, dismissable: true, priority: 90))
        }

        for r in env.reminders.items {
            let late = r.isOverdue
            let soon = r.hasTime && r.due.timeIntervalSinceNow < 15 * 60
            guard late || soon || !r.hasTime else { continue }
            let f = DateFormatter(); f.dateFormat = "H:mm"
            let when = late ? (r.hasTime ? String(localized: "просрочено · \(f.string(from: r.due))") : String(localized: "просрочено"))
                : (r.hasTime ? String(localized: "в \(f.string(from: r.due))") : String(localized: "сегодня"))
            out.append(AttentionItem(id: "rem-\(r.id)", icon: "checklist", appIcon: nil, tint: late ? .red : r.color,
                                     title: r.title, subtitle: when,
                                     actionTitle: String(localized: "Готово"), action: .completeReminder(r.id), dismissable: true,
                                     priority: late ? 92 : (r.hasTime ? 88 : 40)))
        }

        if env.focus.phase == .finished {
            let isWork = env.focus.kind == .work
            out.append(AttentionItem(id: "pomo-\(env.focus.completedInCycle)-\(isWork)", icon: isWork ? "cup.and.saucer.fill" : "play.fill", appIcon: nil,
                                     tint: isWork ? .green : .orange,
                                     title: isWork ? String(localized: "Помидор завершён") : String(localized: "Перерыв закончился"),
                                     subtitle: isWork ? String(localized: "Время отдохнуть") : String(localized: "Возвращаемся к работе"),
                                     actionTitle: isWork ? String(localized: "Перерыв") : String(localized: "К работе"), action: .startBreak, dismissable: true, priority: 80))
        }

        if let issue = env.jira.activeIssue, let original = issue.originalEstimate {
            let spent = issue.progressPeriods.isEmpty ? (issue.timeSpent ?? 0) : issue.timeInWork()
            let left = original - spent
            if left < 3600 {
                out.append(AttentionItem(id: "est-\(issue.key)-\(left < 0)", icon: "exclamationmark.triangle.fill", appIcon: nil,
                                         tint: left < 0 ? .red : .orange,
                                         title: left < 0 ? String(localized: "\(issue.key): эстимейт превышен") : String(localized: "\(issue.key): эстимейт почти исчерпан"),
                                         subtitle: left < 0 ? String(localized: "сверх оценки \(JiraService.format(-left))") : String(localized: "осталось \(JiraService.format(left))"),
                                         actionTitle: String(localized: "Открыть"), action: .openJira(issue.key), dismissable: true, priority: 70))
            }
        }

        for key in newIssues {
            let issue = env.jira.issues.first { $0.key == key }
            out.append(AttentionItem(id: "new-\(key)", icon: "sparkles", appIcon: nil, tint: Theme.jira,
                                     title: issue?.summary ?? key, subtitle: issue?.summary == nil ? String(localized: "назначена на вас") : key,
                                     actionTitle: String(localized: "Открыть"), action: .openJira(key), dismissable: true, priority: 60))
        }

        switch env.calls.stage {
        case .recording:
            out.append(AttentionItem(id: "rec", icon: "record.circle.fill", appIcon: nil, tint: .red,
                                     title: String(localized: "Идёт запись созвона"), subtitle: FocusTimer.format(env.calls.elapsed),
                                     actionTitle: String(localized: "Остановить"), action: .stopCall, dismissable: false, priority: 120))
            if !env.copilot.isActive {
                out.append(AttentionItem(id: "copilot", icon: "sparkles", appIcon: nil, tint: Color(red: 0.62, green: 0.55, blue: 1.0),
                                         title: String(localized: "Помощник на встрече"), subtitle: String(localized: "подскажет, что спросить и что в коде · ⌃⌥H"),
                                         actionTitle: String(localized: "Включить"), action: .meetingAssistant, dismissable: true, priority: 118))
            }
        case .transcribing, .summarizing:
            out.append(AttentionItem(id: "rec-work", icon: "waveform", appIcon: nil, tint: Theme.jira,
                                     title: env.calls.stage == .transcribing ? String(localized: "Расшифровываю созвон") : String(localized: "Готовлю протокол"),
                                     subtitle: String(localized: "на этом компьютере"), actionTitle: nil, action: .none, dismissable: false, priority: 119))
        case .idle:
            if env.calls.micActive {
                out.append(AttentionItem(id: "mic", icon: "mic.fill", appIcon: nil, tint: .orange,
                                         title: String(localized: "Идёт разговор?"), subtitle: env.calls.micStatusText,
                                         actionTitle: String(localized: "Записать"), action: .startCall, dismissable: true, priority: 95))
            }
            if let first = CallRecorder.pendingRecordings().first {
                out.append(AttentionItem(id: "pending-\(first.lastPathComponent)", icon: "waveform.badge.exclamationmark", appIcon: nil, tint: .orange,
                                         title: String(localized: "Запись без протокола"), subtitle: first.lastPathComponent,
                                         actionTitle: String(localized: "Обработать"), action: .processCalls, dismissable: true, priority: 94))
            }
        }

        if let note = env.calls.lastNote, !note.isEmpty, !dismissed.contains("call-\(note)") {
            out.append(AttentionItem(id: "call-\(note)", icon: "text.document.fill", appIcon: nil, tint: Theme.obsidian,
                                     title: String(localized: "Протокол созвона готов"), subtitle: (note as NSString).lastPathComponent,
                                     actionTitle: String(localized: "Открыть"), action: .openNote(note), dismissable: true, priority: 118))
        }
        if let err = env.calls.lastError, !dismissed.contains("callerr-\(err)") {
            out.append(AttentionItem(id: "callerr-\(err)", icon: "exclamationmark.triangle.fill", appIcon: nil, tint: .orange,
                                     title: String(localized: "Запись созвона"), subtitle: err, actionTitle: nil, action: .none, dismissable: true, priority: 117))
        }

        for (id, f) in finished {
            out.append(AttentionItem(id: id, icon: "checkmark.circle.fill", appIcon: f.agent.icon, tint: .green,
                                     title: String(localized: "\(f.agent.title) закончил"), subtitle: "\(f.project) · \(FocusTimer.format(TimeInterval(f.duration))) · \(Self.ago(f.at))",
                                     actionTitle: String(localized: "Перейти"), action: .openAgent(f.agent, host: f.host), dismissable: true, priority: 50))
        }

        for (id, f) in ciFailures {
            // A later green run clears the failure by itself.
            if env.git.status?.name == f.repo, env.git.ci.state == .success { continue }
            out.append(AttentionItem(id: id, icon: "xmark.octagon.fill", appIcon: nil, tint: .red,
                                     title: String(localized: "CI упал: \(f.ci.failedCheck ?? f.ci.title)"),
                                     subtitle: f.ci.prNumber.map { "\(f.repo) · PR #\($0)" } ?? f.repo,
                                     actionTitle: String(localized: "Открыть"), action: .openGit, dismissable: true, priority: 80))
        }

        return out.filter { !dismissed.contains($0.id) }.sorted { $0.priority > $1.priority }
    }

    func perform(_ item: AttentionItem) {
        guard let env else { return }
        switch item.action {
        case .openAgent(let agent, let host):
            for id in [host].compactMap({ $0 }) + agent.appBundleIDs {
                if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { app.activate(); break }
            }
            if item.id.hasPrefix("finished-") { dismiss(item) }
        case .joinMeeting(let id):
            if let e = env.calendar.events.first(where: { $0.id == id }) { env.calendar.join(e) }
        case .openJira(let key):
            if let issue = env.jira.issues.first(where: { $0.key == key }) { env.jira.open(issue) }
            if item.id.hasPrefix("new-") { dismiss(item) }
        case .openNote(let rel):
            env.obsidian.open(relativePath: rel)
            dismiss(item)
        case .meetingAssistant:
            env.copilot.activate()
        case .stopCall:
            Task { await env.calls.finishRecording() }
        case .startCall:
            Task { await env.calls.beginRecording() }
        case .processCalls:
            if let first = CallRecorder.pendingRecordings().first {
                Task { await env.calls.processExisting(folder: first) }
            }
        case .startBreak:
            if env.focus.kind == .work { env.focus.startBreak() } else { env.focus.start(label: env.focus.label) }
        case .openGit:
            if let url = ciFailures[item.id]?.ci.url { NSWorkspace.shared.open(url) }
            dismiss(item)
        case .completeReminder(let id):
            if let r = env.reminders.items.first(where: { $0.id == id }) { env.reminders.complete(r) }
        case .none:
            break
        }
    }

    private static func ago(_ date: Date) -> String {
        let m = Int(Date().timeIntervalSince(date) / 60)
        return m < 1 ? String(localized: "только что") : String(localized: "\(m) мин назад")
    }
}
