import SwiftUI
import UniformTypeIdentifiers

struct NotchRootView: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var player: NowPlayingService
    @EnvironmentObject var shelf: ShelfStore
    @Namespace private var ns

    var body: some View {
        let size = vm.currentSize
        let open = vm.isOpen
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                if !open && vm.musicActive && settings.notchGlowMode == .artwork {
                    NotchMusicGlow(
                        bottomRadius: vm.hud != nil || vm.showsFace ? 16 : 11,
                        tint: player.accent
                    )
                        .frame(width: size.width, height: size.height)
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
                NotchShape(topRadius: open ? 14 : NotchViewModel.collapsedEar, bottomRadius: open ? 30 : (vm.hud != nil || vm.showsFace ? 16 : 11))
                    .fill(Color.black)
                    .overlay(alignment: .top) {
                        // Subtle inner glow when open
                        if open {
                            NotchShape(topRadius: 14, bottomRadius: 30)
                                .stroke(LinearGradient(colors: [.clear, .white.opacity(0.08)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
                                .transition(.opacity)
                        }
                    }
                    .shadow(color: .black.opacity(open ? 0.55 : 0), radius: open ? 24 : 0, y: open ? 10 : 0)

                Group {
                    if open {
                        ExpandedView(ns: ns)
                            .padding(.horizontal, 14 + 12)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).animation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.05)),
                                removal: .opacity.animation(.easeIn(duration: 0.1))))
                    } else {
                        CollapsedView(ns: ns)
                            .padding(.horizontal, 7)
                            .transition(.opacity.animation(.easeOut(duration: 0.15)))
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
            }
            .frame(width: size.width, height: size.height)
            .contentShape(NotchShape(topRadius: 0, bottomRadius: 20))
            .offset(x: open ? 0 : vm.closedOffsetX)
            .onTapGesture {
                guard !vm.isOpen else { return }
                // Right after the assistant offered a breathing break, the click accepts it.
                if AppEnvironment.shared.companion.acceptBreathOffer() { return }
                vm.open(reason: .click)
            }
            .onDrop(of: [.fileURL, .image, .plainText], isTargeted: Binding(
                get: { vm.isDropTargeted },
                set: { t in
                    vm.isDropTargeted = t
                    if t && !vm.isOpen { vm.open(tab: .shelf, reason: .drag) }
                    if t && vm.tab != .shelf { vm.select(NotchTab.shelf) }
                })
            ) { providers in
                let ok = shelf.handle(providers: providers)
                if ok, vm.openReason == .drag {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        if !vm.isTyping, vm.openReason == .drag { vm.close() }
                    }
                }
                return ok
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }
}

/// Collapsed notch while music plays: a soft halo in the cover's accent color hugging the island.
/// With live audio it works like an equalizer — bass swells it, kicks flash it; otherwise it pulses on the beat grid.
private struct NotchMusicGlow: View {
    let bottomRadius: CGFloat
    let tint: Color
    @EnvironmentObject var tempo: TempoService

    var body: some View {
        // The collapsed notch is only a glanceable indicator. 8 fps keeps its pulse readable
        // without keeping the SwiftUI display loop at 30 fps while the full UI is hidden.
        TimelineView(.periodic(from: .now, by: 1 / 8)) { ctx in
            let (bass, kick, energy) = levels(at: ctx.date)
            NotchShape(topRadius: 7, bottomRadius: bottomRadius)
                .stroke(tint, lineWidth: 3 + bass * 4 + kick * 3)
                .blur(radius: 5 + energy * 4 + kick * 4)
                .opacity(0.35 + bass * 0.35 + kick * 0.3)
        }
        .allowsHitTesting(false)
    }

    private func levels(at date: Date) -> (Double, Double, Double) {
        if tempo.audio.isLive {
            let l = tempo.audio.glowLevels()
            return (Double(l.bass), Double(l.kick), Double(l.energy))
        }
        let beat = tempo.beats(at: date).map { exp(-4 * ($0 - $0.rounded(.down))) } ?? 0
        return (beat * 0.6, beat * 0.5, 0.5)
    }
}

// MARK: - Collapsed

struct CollapsedView: View {
    let ns: Namespace.ID
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var companion: Companion
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var player: NowPlayingService
    @EnvironmentObject var focus: FocusTimer
    @EnvironmentObject var battery: BatteryMonitor
    @EnvironmentObject var jira: JiraService
    @EnvironmentObject var ai: AIChatService
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var agents: AgentMonitor
    @EnvironmentObject var calls: CallRecorder

    var body: some View {
        VStack(spacing: 0) {
            if vm.isDocked {
                dockedRow
            } else {
            HStack(spacing: 0) {
                if !vm.activityBesideFace {
                    leftWing.frame(width: max(0, (vm.closedSize.width - vm.cutoutWidth) / 2 - 7), alignment: .leading)
                    Spacer(minLength: vm.cutoutWidth)
                    rightWing.frame(width: max(0, (vm.closedSize.width - vm.cutoutWidth) / 2 - 7), alignment: .trailing)
                }
            }
            .frame(height: vm.notchSize.height)

            if vm.showsFace {
                let faceWidth = FaceAnimations.crop.width * 0.5
                let side = max(0, (vm.closedSize.width - 14 - faceWidth) / 2)
                HStack(spacing: 0) {
                    if vm.activityBesideFace {
                        leftWing.frame(width: side, alignment: .trailing)
                    }
                    FaceView(mood: companion.mood, look: companion.look, scale: 0.5, color: settings.faceColor.color)
                        .frame(height: NotchViewModel.faceHeight, alignment: .top)
                        .allowsHitTesting(false)
                    if vm.activityBesideFace {
                        rightWing.frame(width: side, alignment: .leading)
                    }
                }
                .frame(height: NotchViewModel.faceHeight)
            }
            }

            if AppEnvironment.shared.breathing.isActive {
                BreathingNotchOverlay()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if ai.isResponding {
                AssistantStatusOverlay()
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let hud = vm.hud { hudBody(hud).transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }

    /// Window under the face: face left of the camera, all activity right of it, one menu-bar-high row.
    private var dockedRow: some View {
        let faceScale = min(0.5, vm.notchSize.height / FaceAnimations.crop.height * 0.95)
        return HStack(spacing: 0) {
            FaceView(mood: companion.mood, look: companion.look, scale: faceScale, color: settings.faceColor.color)
                .frame(width: NotchViewModel.dockFaceWidth, height: vm.notchSize.height)
                .allowsHitTesting(false)
            Color.clear.frame(width: vm.cutoutWidth)
            HStack(spacing: 4) {
                leftWing
                rightWing
            }
            // Centred: a single icon sits evenly in the strip instead of leaving room for a second one.
            .frame(width: vm.dockActivityWidth, height: vm.notchSize.height, alignment: .center)
            .clipped()
        }
        .frame(height: vm.notchSize.height)
        .transition(.opacity)
    }

    private var compact: Bool { vm.activityBesideFace || vm.isDocked }
    private var edge: CGFloat { compact ? 2 : 8 }

    /// Inner edge padding (towards the face / camera) and outer edge padding.
    private var innerEdge: Edge.Set { compact ? .trailing : .leading }
    private var outerEdge: Edge.Set { compact ? .leading : .trailing }

    // MARK: Left — music (plus transient badges)

    @ViewBuilder private var leftWing: some View {
        if let badge = companion.badge {
            Group {
                if let image = badge.image {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: compact ? 16 : 20, height: compact ? 16 : 20)
                } else if let symbol = badge.symbol {
                    Image(systemName: symbol).font(.system(size: compact ? 11 : 13, weight: .bold)).foregroundStyle(badge.tint)
                }
            }
            .transition(.scale.combined(with: .opacity))
            .padding(innerEdge, compact ? 6 : 8)
        } else if case .charging = vm.hud {
            Image(systemName: "bolt.fill").font(.system(size: compact ? 11 : 13, weight: .bold)).foregroundStyle(.green)
                .padding(innerEdge, edge)
        } else if vm.workActivity == .call {
            Image(systemName: calls.stage == .recording ? "record.circle.fill" : "waveform")
                .font(.system(size: compact ? 11 : 13, weight: .bold))
                .foregroundStyle(calls.stage == .recording ? Color.red : Theme.jira)
                .padding(innerEdge, edge)
        } else if (vm.musicActive || vm.hud != nil), player.track != nil {
            // Cover on the left; its equalizer lives in the right wing when nothing more important is there.
            ArtworkView(image: player.artwork, size: compact ? 18 : vm.notchSize.height - 10, radius: compact ? 5 : 6)
                .matchedGeometryEffect(id: "artwork", in: ns)
                .padding(innerEdge, compact ? 6 : 4)
        }
    }

    // MARK: Right — work: focus / Jira / meeting, otherwise agents stacked

    @ViewBuilder private var rightWing: some View {
        if case .charging(let level) = vm.hud {
            Text("\(level)%").font(Theme.font(compact ? 10 : 12, .bold)).foregroundStyle(.green).monospacedDigit()
                .padding(outerEdge, edge)
        } else {
            switch vm.workActivity {
            case .call?:
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(calls.stage == .recording ? FocusTimer.format(calls.elapsed)
                         : (calls.stage == .transcribing ? String(localized: "расшифровка") : String(localized: "протокол")))
                        .font(Theme.font(compact ? 9 : 10, .bold)).monospacedDigit()
                        .foregroundStyle(calls.stage == .recording ? Color.red : Theme.jira)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(outerEdge, edge)
            case .focus?:
                HStack(spacing: 4) {
                    Ring(progress: focus.progress, tint: focusTint, lineWidth: 2.5).frame(width: 11, height: 11)
                    Text(FocusTimer.format(focus.remaining))
                        .font(Theme.font(compact ? 10 : 11, .bold)).monospacedDigit().foregroundStyle(focusTint)
                        .contentTransition(.numericText(countsDown: true))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    agentDots
                }
                .padding(outerEdge, edge)
            case .jira?:
                HStack(spacing: 4) {
                    VStack(alignment: compact ? .leading : .trailing, spacing: 0) {
                        Text(jira.sessionKey ?? "").font(Theme.font(8, .bold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).minimumScaleFactor(0.6)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(FocusTimer.format(jira.sessionElapsed(at: ctx.date)))
                                .font(Theme.font(10, .bold)).monospacedDigit().foregroundStyle(Theme.jira)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    agentDots
                }
                .padding(outerEdge, edge)
            case .meeting?:
                if let e = calendar.next {
                    HStack(spacing: 4) {
                        VStack(alignment: compact ? .leading : .trailing, spacing: 0) {
                            Text(e.title).font(Theme.font(8, .bold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                            TimelineView(.periodic(from: .now, by: 15)) { _ in
                                Text(e.isNow ? String(localized: "сейчас") : String(localized: "через \(max(e.minutesUntil, 0)) мин"))
                                    .font(Theme.font(9, .bold)).monospacedDigit().foregroundStyle(e.color)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        agentDots
                    }
                    .padding(outerEdge, edge)
                }
            case .agent?:
                VStack(alignment: compact ? .leading : .trailing, spacing: 1) {
                    ForEach(agents.groups.prefix(2)) { group in
                        AgentRow(group: group, alignLeading: compact)
                    }
                }
                .padding(outerEdge, edge)
            default:
                if vm.musicActive, let t = player.track, companion.badge == nil {
                    EqualizerBars(isPlaying: t.isPlaying, tint: player.accent, bars: compact ? 3 : 4, height: compact ? 10 : 13)
                        .padding(outerEdge, compact ? 6 : 8)
                }
            }
        }
    }

    private var focusTint: Color { focus.phase == .finished || focus.kind.isBreak ? .green : .orange }

    /// Agents squeezed to dots while a timer or meeting owns the right side.
    @ViewBuilder private var agentDots: some View {
        let groups = agents.groups
        if !groups.isEmpty {
            VStack(spacing: 3) {
                ForEach(groups.prefix(2)) { g in
                    Circle().fill(g.isWaiting ? Color.orange : g.agent.tint).frame(width: 4, height: 4)
                        .opacity(g.isWorking || g.isWaiting ? 1 : 0.4)
                }
            }
        }
    }

    @ViewBuilder private func hudBody(_ hud: NotchHUD) -> some View {
        switch hud {
        case .track(let title, let artist):
            VStack(spacing: 1) {
                Text(title).font(Theme.font(13, .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8)
                Text(artist).font(Theme.font(11)).foregroundStyle(player.accent.opacity(0.9)).lineLimit(1)
            }
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: 40)
        case .timerDone:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(focus.kind == .work ? String(localized: "Перерыв закончился — к работе") : String(localized: "\(focus.label): пора отдохнуть")).font(Theme.font(13, .semibold)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }.padding(.horizontal, 12).frame(height: 32)
        case .message(let icon, let text):
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Theme.obsidian)
                Text(text).font(Theme.font(12, .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
            }.padding(.horizontal, 12).frame(height: 32)
        case .speech(let text):
            Text(text).font(Theme.font(12, .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 12).frame(height: 26)
        case .charging:
            EmptyView()
        }
    }
}

/// One agent line in the notch: icon with an activity ring + its own timer.
private struct AgentRow: View {
    let group: AgentMonitor.Group
    let alignLeading: Bool

    var body: some View {
        HStack(spacing: 3) {
            if !alignLeading { timer }
            icon
            if alignLeading { timer }
        }
        .frame(height: 14)
        .help("\(group.agent.title): \(group.projects)")
    }

    private var icon: some View {
        ZStack {
            if let img = group.agent.icon {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: 11, height: 11)
            } else {
                Image(systemName: group.agent.fallbackSymbol).font(.system(size: 8, weight: .bold)).foregroundStyle(group.agent.tint)
            }
            if group.isWaiting {
                Circle().fill(Color.orange).frame(width: 5, height: 5).offset(x: 5, y: -5)
            } else if group.isWorking {
                TimelineView(.periodic(from: .now, by: 1 / 12)) { ctx in
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(group.agent.tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                        .frame(width: 14, height: 14)
                        .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate * 360))
                }
            }
        }
        .frame(width: 14, height: 14)
    }

    private var timer: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            HStack(spacing: 2) {
                Text(group.isWaiting ? String(localized: "ждёт") : FocusTimer.format(ctx.date.timeIntervalSince(group.startedAt)))
                    .font(Theme.font(9, .bold)).monospacedDigit()
                    .foregroundStyle(group.isWaiting ? Color.orange : group.agent.tint)
                if group.sessions.count > 1 {
                    Text("×\(group.sessions.count)").font(Theme.font(8, .bold)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

private struct AssistantStatusOverlay: View {
    @EnvironmentObject var ai: AIChatService

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(ai.provider.tint.opacity(0.18)).frame(width: 30, height: 30)
                    Circle().stroke(ai.provider.tint.opacity(0.55), lineWidth: 1.5)
                        .frame(width: 18, height: 18)
                        .scaleEffect(1 + CGFloat(max(0, sin(t * 3))) * 0.16)
                    Image(systemName: "sparkles").font(.system(size: 12, weight: .bold)).foregroundStyle(ai.provider.tint)
                }
                Text(String(localized: "Готовлю ответ")).font(Theme.font(12, .semibold)).foregroundStyle(.white)
                EqualizerBars(isPlaying: true, tint: ai.provider.tint, bars: 5, height: 12)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note").font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Expanded

/// Everything running at once: track, each agent with its own timer, the active timer.
private struct NowStrip: View {
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var player: NowPlayingService
    @EnvironmentObject var agents: AgentMonitor
    @EnvironmentObject var focus: FocusTimer
    @EnvironmentObject var jira: JiraService
    @EnvironmentObject var calls: CallRecorder
    @EnvironmentObject var copilot: MeetingCopilot

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
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
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                Text(s.state == .waiting ? String(localized: "ждёт ответа") : FocusTimer.format(ctx.date.timeIntervalSince(s.startedAt)))
                                    .font(Theme.font(10, .bold)).monospacedDigit()
                                    .foregroundStyle(s.state == .waiting ? Color.orange : s.agent.tint)
                            }
                        }
                        .onTapGesture { activate(s.agent) }
                        .help(String(localized: "Открыть \(s.agent.title)"))
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

    private func activate(_ agent: AgentKind) {
        for id in agent.appBundleIDs {
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

struct ExpandedView: View {
    let ns: Namespace.ID
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: vm.notchSize.height)
            if vm.showsNowStrip {
                NowStrip()
                    .frame(height: NotchViewModel.nowStripHeight - 6)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
            if vm.showsPageSwitcher {
                PageSwitcher()
                    .frame(height: NotchViewModel.pageSwitcherHeight - 6)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 8)
                .padding(.bottom, 14)
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            TabBar()
            Spacer(minLength: vm.notchSize.width + 12)
            HeaderStatus()
        }
    }

    @ViewBuilder private var content: some View {
        ZStack(alignment: .top) {
            switch vm.tab {
            case .assistant: CompanionView().transition(.tabSwitch)
            case .ai: AIChatView().transition(.tabSwitch)
            case .home: MediaView(ns: ns).transition(.tabSwitch)
            case .health: HealthView().transition(.tabSwitch)
            case .jira: JiraView().transition(.tabSwitch)
            case .git: GitView().transition(.tabSwitch)
            case .notes: NotesView().transition(.tabSwitch)
            case .shelf: ShelfView().transition(.tabSwitch)
            case .clipboard: ClipboardView().transition(.tabSwitch)
            case .focus: FocusView().transition(.tabSwitch)
            }
        }
    }
}

extension AnyTransition {
    static var tabSwitch: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: 6)).animation(.easeOut(duration: 0.22).delay(0.04)),
                    removal: .opacity.animation(.easeIn(duration: 0.08)))
    }
}

struct TabBar: View {
    @EnvironmentObject var vm: NotchViewModel
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
    }
}

/// Switches pages inside a group (Помощник / Чат ИИ, Jira / Git / Фокус, Полка / Буфер).
struct PageSwitcher: View {
    @EnvironmentObject var vm: NotchViewModel
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

    var body: some View {
        HStack(spacing: 8) {
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
