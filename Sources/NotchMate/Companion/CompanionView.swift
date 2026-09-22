import SwiftUI

/// Помощник: day timeline on top, Taby's line with what needs attention, question field below.
struct CompanionView: View {
    @EnvironmentObject var companion: Companion
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var ai: AIChatService
    @EnvironmentObject var attention: AttentionCenter
    @EnvironmentObject var vm: NotchViewModel
    @EnvironmentObject var calendar: CalendarService
    @EnvironmentObject var reminders: RemindersService
    @EnvironmentObject var focus: FocusTimer

    @State private var question = ""
    @FocusState private var inputFocused: Bool

    private let quick = [String(localized: "Что у меня сегодня?"), String(localized: "Что сейчас важнее?"), String(localized: "План до вечера")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DayTimeline(events: calendar.hasAccess ? calendar.events : [],
                        reminders: reminders.items.filter { $0.hasTime },
                        focusEnd: focusEnd, hasAccess: calendar.hasAccess || reminders.hasAccess,
                        open: { e in if e.meetingURL != nil { calendar.join(e) } },
                        complete: { reminders.complete($0) },
                        snooze: { reminders.snooze($0) },
                        openReminders: { reminders.openApp() })
            .frame(height: 62)

            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black)
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(settings.faceColor.color.opacity(0.18), lineWidth: 1))
                    FaceView(mood: companion.mood, look: companion.look, scale: 0.5, color: settings.faceColor.color)
                }
                .frame(width: 52, height: 40)

                VStack(alignment: .leading, spacing: 6) {
                    phrase
                    chips
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            inputRow
        }
        .onChange(of: inputFocused) { _, f in vm.isTyping = f }
    }

    private var focusEnd: Date? {
        focus.phase == .running ? Date().addingTimeInterval(focus.remaining) : nil
    }

    // MARK: Taby's line

    private var phrase: some View {
        Group {
            if ai.tabyThinking && ai.tabyAnswer.isEmpty {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(Theme.secondary).frame(width: 5, height: 5) }
                }
                .frame(height: 16)
            } else if !ai.tabyAnswer.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(ai.tabyAnswer).font(Theme.font(12.5)).foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxHeight: attention.items.isEmpty ? 64 : 36)
            } else {
                Text(greeting).font(Theme.font(12.5)).foregroundStyle(.white.opacity(0.92)).lineLimit(2)
            }
        }
    }

    private var greeting: AttributedString {
        let items = attention.items
        if let r = reminders.items.first(where: { $0.hasTime && $0.due > Date() }), Calendar.current.isDateInToday(r.due),
           calendar.next.map({ $0.isNow || $0.start > r.due }) ?? true, calendar.next?.isNow != true {
            let mins = Int(ceil(r.due.timeIntervalSinceNow / 60))
            let until = mins < 60 ? String(localized: "\(mins) мин") : String(localized: "\(mins / 60) ч \(mins % 60) мин")
            return md(String(localized: "Через **\(until)** напомню: «\(r.title)»."))
        }
        if let e = calendar.hasAccess ? calendar.next : nil, Calendar.current.isDateInToday(e.start) {
            if e.isNow {
                return md(String(localized: "Сейчас идёт **\(e.title)**") + (items.isEmpty ? "." : String(localized: ", и ещё кое-что ждёт тебя.")))
            }
            let mins = e.minutesUntil
            let until = mins < 60 ? String(localized: "\(mins) мин") : String(localized: "\(mins / 60) ч \(mins % 60) мин")
            return md(String(localized: "До «\(e.title)» **\(until)**.") + (items.isEmpty ? String(localized: " Время свободно.") : String(localized: " Успеешь разобрать дела ниже.")))
        }
        if items.isEmpty { return md(String(localized: "Сегодня больше ничего не запланировано. Спроси меня о дне.")) }
        return md(items.count == 1 ? String(localized: "Одно дело ждёт тебя.") : String(localized: "\(items.count) дела ждут внимания."))
    }

    private func md(_ s: String) -> AttributedString { (try? AttributedString(markdown: s)) ?? AttributedString(s) }

    private var chips: some View {
        FlowLayout(spacing: 5) {
            if settings.remindersEnabled, reminders.status != .fullAccess {
                Button {
                    Task { await PermissionCenter.shared.request(.reminders); reminders.refresh() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checklist").font(.system(size: 10, weight: .semibold))
                        Text(reminders.status == .notDetermined ? String(localized: "Показывать напоминания") : String(localized: "Разрешить доступ к напоминаниям"))
                            .font(Theme.font(11, .medium))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(Capsule().fill(settings.faceColor.color))
                }
                .buttonStyle(PressableStyle())
                .help(String(localized: "Дела из приложения «Напоминания» появятся на шкале дня"))
            }
            ForEach(attention.items.prefix(4)) { item in
                Button { attention.perform(item) } label: {
                    HStack(spacing: 5) {
                        if let img = item.appIcon {
                            Image(nsImage: img).resizable().frame(width: 12, height: 12)
                        } else {
                            Circle().fill(item.tint).frame(width: 6, height: 6)
                        }
                        Text(item.title).font(Theme.font(11, .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                        Text(item.subtitle).font(Theme.font(11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    .padding(.horizontal, 9).frame(height: 22).frame(maxWidth: 260)
                    .background(Capsule().fill(item.tint.opacity(0.14)))
                }
                .buttonStyle(PressableStyle())
                .help(item.actionTitle ?? item.title)
                .contextMenu {
                    if let title = item.actionTitle { Button(title) { attention.perform(item) } }
                    if item.dismissable { Button(String(localized: "Убрать")) { attention.dismiss(item) } }
                }
            }
        }
        .animation(.spring(response: 0.35), value: attention.items)
    }

    // MARK: Ask

    @ViewBuilder
    private var inputRow: some View {
        if ai.isReady(ai.provider) {
            HStack(spacing: 6) {
                TextField("", text: $question, prompt: Text(String(localized: "Спросить \(settings.companionName) про день…")).foregroundStyle(Theme.tertiary))
                    .textFieldStyle(.plain).font(Theme.font(13)).foregroundStyle(.white)
                    .focused($inputFocused)
                    .onSubmit(ask)
                if question.isEmpty && !inputFocused && !ai.tabyThinking {
                    ForEach(quick, id: \.self) { q in
                        Button { question = q; ask() } label: {
                            Text(q).font(Theme.font(11)).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if ai.tabyThinking {
                    IconButton(systemName: "stop.fill", size: 9, frame: 24, filled: true, help: String(localized: "Остановить")) { ai.stopTaby() }
                } else {
                    Button(action: ask) {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.black)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(question.isEmpty ? Color.white.opacity(0.3) : settings.faceColor.color))
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.leading, 12).padding(.trailing, 4).frame(height: 32)
            .card(radius: 16, fill: Color.white.opacity(inputFocused ? 0.1 : 0.06))
        } else {
            PillButton(title: String(localized: "Подключить ИИ"), icon: "sparkles", tint: settings.faceColor.color, prominent: true) {
                NotificationCenter.default.post(name: .notchMateOpenSettings, object: nil)
            }
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !ai.tabyThinking else { return }
        question = ""
        ai.askTaby(q)
    }
}

/// Horizontal line of the day: calendar events on their hours, a running focus block and a "now" marker.
private struct DayTimeline: View {
    let events: [CalendarEvent]
    let reminders: [ReminderItem]
    let focusEnd: Date?
    let hasAccess: Bool
    let open: (CalendarEvent) -> Void
    let complete: (ReminderItem) -> Void
    let snooze: (ReminderItem) -> Void
    let openReminders: () -> Void

    /// Visible hours: pinch, scroll over the strip or pick a preset. Remembered between launches.
    @AppStorage("timelineHours") private var hours: Double = 10
    @State private var hovering = false
    @State private var scrollMonitor: Any?
    @State private var pinchMonitor: Any?

    private static let minHours = 1.0, maxHours = 24.0
    private static let presets: [Double] = [2, 6, 12, 24]
    private var span: TimeInterval { hours * 3600 }

    var body: some View {
        TimelineView(.periodic(from: .now, by: hours <= 3 ? 10 : 30)) { ctx in
            let now = ctx.date
            let from = windowStart(now)
            let to = from.addingTimeInterval(span)
            GeometryReader { geo in
                let w = geo.size.width
                let x = { (d: Date) -> CGFloat in CGFloat(d.timeIntervalSince(from) / span) * w }
                let visible = events.filter { $0.end > from && $0.start < to }

                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: w, height: geo.size.height)
                    // Track: past part brighter.
                    Capsule().fill(Color.white.opacity(0.1)).frame(width: w, height: 2).offset(y: 25)
                    Capsule().fill(Color.white.opacity(0.45)).frame(width: max(0, x(now)), height: 2).offset(y: 25)

                    ForEach(visible) { e in
                        let x0 = max(0, x(e.start)), x1 = min(w, x(e.end))
                        let past = e.end <= now
                        // The title may be wider than the block, but not wider than the card.
                        let titleWidth = max(min(max(x1 - x0, 64), w - x0), min(64, w))
                        let titleX = min(x0, w - titleWidth)
                        Button { open(e) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.title).font(Theme.font(10, .medium))
                                    .foregroundStyle(past ? Theme.tertiary : Theme.secondary)
                                    .lineLimit(1).truncationMode(.tail)
                                    .frame(width: titleWidth, alignment: .leading)
                                    .offset(x: titleX - x0)
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(e.color.opacity(past ? 0.3 : (e.isNow ? 1 : 0.75)))
                                    .frame(width: max(x1 - x0, 6), height: 16)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(Self.describe(e))
                        .offset(x: x0, y: 1)
                    }

                    ForEach(reminders.filter { $0.due >= from && $0.due <= to }) { r in
                        let rx = x(r.due)
                        let late = r.due < now
                        Menu {
                            Button(String(localized: "Готово")) { complete(r) }
                            Button(String(localized: "Отложить на час")) { snooze(r) }
                            Divider()
                            Button(String(localized: "Открыть «Напоминания»")) { openReminders() }
                        } label: {
                            VStack(spacing: 2) {
                                Text(r.title).font(Theme.font(10, .medium))
                                    .foregroundStyle(late ? Color.red.opacity(0.9) : Theme.secondary)
                                    .lineLimit(1).frame(maxWidth: 90)
                                ZStack(alignment: .top) {
                                    Rectangle().fill(r.color.opacity(0.7)).frame(width: 1.5, height: 14).offset(y: 4)
                                    Circle().fill(late ? Color.red : r.color).frame(width: 8, height: 8)
                                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                                }
                                .frame(height: 18)
                            }
                            .fixedSize()
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .help("\(r.title) · \(Self.time(r.due))")
                        .alignmentGuide(.leading) { d in d[HorizontalAlignment.center] }
                        .offset(x: min(max(rx, 20), w - 20), y: 1)
                    }

                    if let focusEnd, focusEnd > now {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.green.opacity(0.3))
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.green, lineWidth: 1))
                            .frame(width: max(4, min(w, x(focusEnd)) - x(now)), height: 10)
                            .offset(x: x(now), y: 21)
                            .help(String(localized: "Фокус до \(Self.time(focusEnd))"))
                    }

                    Circle().fill(Color.white).frame(width: 10, height: 10)
                        .background(Circle().fill(Color.white.opacity(0.2)).frame(width: 18, height: 18))
                        .offset(x: x(now) - 5, y: 21)

                    // Hour labels, denser when zoomed in.
                    ForEach(hourMarks(from: from, to: to).filter { x($0) < w - 44 }, id: \.self) { d in
                        Text(Self.time(d)).font(Theme.font(9.5)).foregroundStyle(Theme.tertiary).monospacedDigit()
                            .fixedSize()
                            .offset(x: max(0, x(d) - 14), y: 34)
                            .transition(.opacity)
                    }
                    // End of the visible range, right-aligned to the edge.
                    Text(Self.time(to)).font(Theme.font(9.5)).foregroundStyle(Theme.tertiary).monospacedDigit()
                        .fixedSize()
                        .frame(width: w, alignment: .trailing)
                        .offset(y: 34)

                    if !hasAccess {
                        Text(String(localized: "Дай доступ к календарю или напоминаниям, чтобы видеть день"))
                            .font(Theme.font(10)).foregroundStyle(Theme.tertiary).offset(y: 2)
                    } else if visible.isEmpty && !reminders.contains(where: { $0.due >= from && $0.due <= to }) {
                        Text(String(localized: "Свободный день")).font(Theme.font(10)).foregroundStyle(Theme.tertiary).offset(y: 2)
                    }
                }
                .frame(width: w, height: geo.size.height, alignment: .topLeading)
                .clipped()
            }
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
        .card(radius: 14)
        .overlay(alignment: .topTrailing) { if hovering { zoomPresets.transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing))) } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { hours = 10 } }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .onAppear(perform: installScrollZoom)
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            if let pinchMonitor { NSEvent.removeMonitor(pinchMonitor) }
            scrollMonitor = nil
            pinchMonitor = nil
        }
    }

    private var zoomPresets: some View {
        HStack(spacing: 2) {
            ForEach(Self.presets, id: \.self) { p in
                let active = abs(hours - p) < 0.5
                Button {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { hours = p }
                } label: {
                    Text(String(localized: "\(Int(p))ч")).font(Theme.font(9.5, .semibold)).monospacedDigit()
                        .foregroundStyle(active ? Color.black : Theme.secondary)
                        .padding(.horizontal, 6).frame(height: 16)
                        .background(Capsule().fill(active ? Color.white.opacity(0.85) : Color.clear))
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.black.opacity(0.75)).overlay(Capsule().strokeBorder(Theme.stroke)))
        .padding(6)
    }

    /// Scroll wheel / two-finger scroll over the strip zooms it (only while the pointer is here).
    private func installScrollZoom() {
        guard scrollMonitor == nil else { return }
        let hoursBinding = $hours
        let isHovering = { hovering }
        // Trackpad pinch and scroll both arrive as events; the panel doesn't take SwiftUI's magnify gesture.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard isHovering() else { return event }
            return Self.zoom(hoursBinding, by: event)
        }
        // While another app is active the pinch goes to it; watching it globally still zooms the strip under the pointer.
        pinchMonitor = NSEvent.addGlobalMonitorForEvents(matching: .magnify) { event in
            guard isHovering() else { return }
            _ = Self.zoom(hoursBinding, by: event)
        }
    }

    private static func zoom(_ hoursBinding: Binding<Double>, by event: NSEvent) -> NSEvent? {
        if event.type == .magnify {
            hoursBinding.wrappedValue = clamp(hoursBinding.wrappedValue / (1 + Double(event.magnification)))
            return nil
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        guard abs(delta) > 0.01 else { return nil }
        hoursBinding.wrappedValue = clamp(hoursBinding.wrappedValue * exp(-Double(delta) * 0.012))
        return nil
    }

    private static func clamp(_ h: Double) -> Double { min(maxHours, max(minHours, h)) }

    /// A fifth of the window is the past; continuous (not snapped) so zooming is smooth.
    private func windowStart(_ now: Date) -> Date {
        now.addingTimeInterval(-span * 0.2)
    }

    private func hourMarks(from: Date, to: Date) -> [Date] {
        let step: Int = hours <= 2.5 ? 30 : hours <= 6 ? 60 : hours <= 13 ? 120 : hours <= 19 ? 180 : 240
        let cal = Calendar.current
        var d = cal.dateInterval(of: .hour, for: from)?.start ?? from
        var out: [Date] = []
        while d <= to {
            let minutes = cal.component(.hour, from: d) * 60 + cal.component(.minute, from: d)
            if d >= from, minutes % step == 0 { out.append(d) }
            d = d.addingTimeInterval(30 * 60)
        }
        return out
    }

    private static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "H:mm"; return f.string(from: d)
    }

    private static func describe(_ e: CalendarEvent) -> String {
        var s = "\(e.title) · \(time(e.start))–\(time(e.end))"
        if let loc = e.location, !loc.isEmpty { s += " · \(loc)" }
        return s
    }
}

/// Speech bubble with a small tail pointing at the face.
private struct BubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(roundedRect: rect.insetBy(dx: 0, dy: 0), cornerRadius: 12, style: .continuous)
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + 18))
        p.addLine(to: CGPoint(x: rect.minX - 6, y: rect.minY + 24))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + 30))
        p.closeSubpath()
        return p
    }
}

/// Simple wrapping layout for chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
