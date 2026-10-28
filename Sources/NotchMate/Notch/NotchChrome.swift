import AppKit
import SwiftUI

// Panel chrome around the pages: Now strip, tab bar, page switcher, header status and the headphones HUD.

struct HeadphonesHUD: View {
    let battery: HeadphonesBattery

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                .frame(width: 26)
            Text(battery.name).font(Theme.font(12, .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 4)
            if let main = battery.main { level(main, label: nil) }
            if let left = battery.left { level(left, label: "L") }
            if let right = battery.right { level(right, label: "R") }
            if let caseLevel = battery.caseLevel { level(caseLevel, label: nil, caseSymbol: true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        let name = battery.name.lowercased()
        if name.contains("max") { return "airpodsmax" }
        if name.contains("pro") { return "airpodspro" }
        if name.contains("airpods") { return "airpods" }
        return "headphones"
    }

    private func level(_ value: Int, label: String?, caseSymbol: Bool = false) -> some View {
        let tint: Color = value <= 20 ? .red : .green
        return HStack(spacing: 4) {
            ZStack {
                Ring(progress: Double(value) / 100, tint: tint, lineWidth: 2.5)
                if caseSymbol {
                    Image(systemName: "airpods.chargingcase.fill").font(.system(size: 7)).foregroundStyle(.white.opacity(0.8))
                } else if let label {
                    Text(label).font(Theme.font(8, .bold)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 20, height: 20)
            Text("\(value)%").font(Theme.font(11, .bold)).monospacedDigit().foregroundStyle(tint)
        }
    }

    private var accessibilityText: String {
        var parts = [battery.name]
        if let main = battery.main { parts.append("\(main)%") }
        if let left = battery.left { parts.append(String(localized: "левый \(left)%")) }
        if let right = battery.right { parts.append(String(localized: "правый \(right)%")) }
        if let caseLevel = battery.caseLevel { parts.append(String(localized: "кейс \(caseLevel)%")) }
        return parts.joined(separator: ", ")
    }
}

/// One agent line in the notch: icon with an activity ring + its own timer.
// MARK: - Expanded

/// Everything running at once: track, each agent with its own timer, the active timer.
struct NowStrip: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var player: NowPlayingService
    @EnvironmentObject var agents: AgentMonitor
    @EnvironmentObject var focus: FocusTimer
    @EnvironmentObject var jira: JiraService
    @EnvironmentObject var calls: CallRecorder
    @EnvironmentObject var copilot: MeetingCopilot
    @EnvironmentObject var calendar: CalendarService

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if let meeting = vm.stripMeeting {
                    chip {
                        Circle().fill(meeting.color).frame(width: 7, height: 7)
                        Text(meeting.title).font(Theme.font(11, .semibold)).foregroundStyle(.white).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                        TimelineView(.periodic(from: .now, by: 15)) { _ in
                            Text(meeting.isNow ? String(localized: "идёт") : String(localized: "через \(max(meeting.minutesUntil, 0)) мин"))
                                .font(Theme.font(10, .bold)).monospacedDigit().foregroundStyle(meeting.color)
                        }
                        Button { calendar.join(meeting) } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "video.fill").font(.system(size: 9, weight: .bold))
                                Text(String(localized: "Подключиться")).font(Theme.font(10, .bold))
                            }
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(Capsule().fill(Color.green))
                        }
                        .buttonStyle(PressableStyle())
                        .help(meeting.meetingURL?.host() ?? "")
                    }
                    .accessibilityElement(children: .combine)
                }
                if calls.stage != .idle {
                    chip {
                        Image(systemName: calls.stage == .recording ? "record.circle.fill" : "waveform")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(calls.stage == .recording ? Color.red : Theme.jira)
                        Text(calls.stage == .recording ? String(localized: "Запись созвона") : (calls.stage == .transcribing ? String(localized: "Расшифровка") : String(localized: "Протокол")))
                            .font(Theme.font(11, .semibold)).foregroundStyle(.white)
                        if calls.stage == .recording {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(FocusTimer.format(calls.elapsed)).font(Theme.font(10, .bold)).monospacedDigit().foregroundStyle(.red)
                            }
                            Button { Task { await calls.finishRecording() } } label: {
                                Text(String(localized: "Стоп")).font(Theme.font(10, .bold)).foregroundStyle(.black)
                                    .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Color.red))
                            }
                            .buttonStyle(PressableStyle())
                            Button { copilot.toggleOrHint() } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold))
                                    Text(copilot.isActive ? String(localized: "Подсказать") : String(localized: "Помощник")).font(Theme.font(10, .bold))
                                }
                                .foregroundStyle(.black)
                                .padding(.horizontal, 7).frame(height: 18)
                                .background(Capsule().fill(Color(red: 0.62, green: 0.55, blue: 1.0)))
                            }
                            .buttonStyle(PressableStyle())
                            .help(String(localized: "Подсказки на встрече — что спросить, что ответить, что в коде (⌃⌥H)"))
                        }
                    }
                }
                if vm.stripShowsMusic, let t = player.track {
                    chip {
                        ArtworkView(image: player.artwork, size: 18, radius: 4)
                        Text(t.title).font(Theme.font(11, .semibold)).foregroundStyle(.white).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                        Button { player.send(.toggle) } label: {
                            Image(systemName: t.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        }.buttonStyle(PressableStyle())
                        Button { player.send(.next) } label: {
                            Image(systemName: "forward.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                        }.buttonStyle(PressableStyle())
                    }
                }
                ForEach(agents.groups) { g in
                    ForEach(g.sessions) { s in
                        chip {
                            if let icon = s.agent.icon {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            } else {
                                Image(systemName: s.agent.fallbackSymbol).font(.system(size: 10, weight: .bold)).foregroundStyle(s.agent.tint)
                            }
                            Text(s.project).font(Theme.font(11, .semibold)).foregroundStyle(.white).lineLimit(1)
                            if s.state == .waiting, let message = s.waitingMessage {
                                Text(message).font(Theme.font(10, .semibold)).foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1).frame(maxWidth: 180, alignment: .leading)
                            }
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(s.state == .waiting ? String(localized: "ждёт ответа") : FocusTimer.format(ctx.date.timeIntervalSince(s.startedAt)))
                                    .font(Theme.font(10, .bold)).monospacedDigit()
                                    .foregroundStyle(s.state == .waiting ? Color.orange : s.agent.tint)
                            }
                        }
                        .onTapGesture { activate(s) }
                        .help(s.waitingMessage ?? String(localized: "Открыть \(s.agent.title)"))
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { activate(s) }
                    }
                }
                if focus.isActive {
                    chip {
                        Ring(progress: focus.progress, tint: focus.kind.isBreak ? .green : .orange, lineWidth: 2).frame(width: 12, height: 12)
                        Text(focus.kind.title).font(Theme.font(11, .semibold)).foregroundStyle(.white)
                        Text(FocusTimer.format(focus.remaining)).font(Theme.font(10, .bold)).monospacedDigit().foregroundStyle(focus.kind.isBreak ? .green : .orange)
                    }
                } else if jira.isTracking, let key = jira.sessionKey {
                    chip {
                        Image(systemName: "briefcase.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.jira)
                        Text(key).font(Theme.font(11, .semibold)).foregroundStyle(.white)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(FocusTimer.format(jira.sessionElapsed(at: ctx.date))).font(Theme.font(10, .bold)).monospacedDigit().foregroundStyle(Theme.jira)
                        }
                    }
                }
            }
        }
    }

    private func chip<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .card(radius: 13)
    }

    private func activate(_ session: AgentSession) {
        if let id = session.hostBundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            app.activate()
            return
        }
        for id in session.agent.appBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
                return
            }
        }
        for id in ["com.googlecode.iterm2", "com.apple.Terminal", "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode"] {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first { app.activate(); return }
        }
    }
}

struct TabBar: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var settings = Settings.shared
    @Namespace private var tabNS

    var body: some View {
        HStack(spacing: 2) {
            let groups = NotchGroup.visible
            ForEach(Array(groups.enumerated()), id: \.element) { i, group in
                TabButton(group: group, index: i + 1, selected: vm.tab.group == group, ns: tabNS) { vm.select(group) }
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }
}

private struct TabButton: View {
    let group: NotchGroup
    let index: Int
    let selected: Bool
    let ns: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: group.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? .black : .white.opacity(hovering ? 0.95 : 0.6))
                .frame(width: 26, height: 22)
                .background {
                    if selected {
                        Capsule().fill(Color.white).matchedGeometryEffect(id: "tabpill", in: ns)
                    } else if hovering {
                        Capsule().fill(Theme.surface)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("\(group.title)  ⌘\(index)")
        .accessibilityLabel(group.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Switches pages inside a group (Помощник / Чат ИИ, Jira / Git / Фокус, Полка / Буфер).
struct PageSwitcher: View {
    @EnvironmentObject var vm: NotchViewModel
    @ObservedObject private var settings = Settings.shared
    @Namespace private var pageNS

    var body: some View {
        HStack {
            HStack(spacing: 2) {
                ForEach(vm.tab.group.pages) { page in
                    let selected = vm.tab == page
                    Button { vm.select(page) } label: {
                        Label(page.title, systemImage: page.icon).labelStyle(.titleAndIcon)
                            .font(Theme.font(11, .semibold))
                            .foregroundStyle(selected ? .black : .white.opacity(0.65))
                            .padding(.horizontal, 10).frame(height: 22)
                            .background {
                                if selected { Capsule().fill(Color.white).matchedGeometryEffect(id: "pagepill", in: pageNS) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            Spacer()
        }
    }
}

struct HeaderStatus: View {
    @EnvironmentObject var battery: BatteryMonitor
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var weather: WeatherService
    @EnvironmentObject var settings: Settings

    var body: some View {
        HStack(spacing: 8) {
            if settings.pluginEnabled(.weather), let report = weather.report {
                HStack(spacing: 3) {
                    Image(systemName: report.symbol).font(.system(size: 11)).symbolRenderingMode(.multicolor)
                    Text("\(Int(report.temperature.rounded()))°").font(Theme.font(11, .semibold)).monospacedDigit()
                }
                .foregroundStyle(Theme.secondary)
                .help(weatherHelp(report))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(weatherHelp(report))
            }
            TimelineView(.everyMinute) { ctx in
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(Theme.font(12, .semibold)).foregroundStyle(Theme.secondary).monospacedDigit()
            }
            if battery.hasBattery {
                HStack(spacing: 3) {
                    Text("\(battery.level)%").font(Theme.font(11, .semibold)).monospacedDigit()
                    Image(systemName: batterySymbol).font(.system(size: 13))
                        .symbolRenderingMode(.hierarchical)
                }
                .foregroundStyle(battery.isCharging ? .green : (battery.level <= 20 ? .red : Theme.secondary))
            }
            IconButton(systemName: "gearshape.fill", size: 11, frame: 24, help: String(localized: "Настройки  ⌘,")) {
                NotificationCenter.default.post(name: .notchMateOpenSettings, object: nil)
            }
        }
    }

    private func weatherHelp(_ report: WeatherReport) -> String {
        var text = "\(weather.place?.name ?? ""): \(Int(report.temperature.rounded()))°, \(report.summary.lowercased())"
        if let wet = report.hours.first(where: { $0.time > Date() && $0.precipitationChance >= 40 }) {
            text += String(localized: " · осадки \(wet.precipitationChance)% к \(wet.time.formatted(date: .omitted, time: .shortened))")
        }
        return text
    }

    private var batterySymbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
