import Charts
import SwiftUI

struct HealthView: View {
    @EnvironmentObject var health: HealthService
    @EnvironmentObject var breathing: BreathingCoach
    @State private var page: Page = .today

    enum Page: String, CaseIterable, Identifiable {
        case today, week, insights
        var id: String { rawValue }
        var title: String {
            switch self {
            case .today: return String(localized: "Сегодня")
            case .week: return String(localized: "Неделя")
            case .insights: return String(localized: "Инсайты")
            }
        }
    }

    var body: some View {
        Group {
            if breathing.isActive {
                BreathingPanel()
            } else if !health.isEnabled || !health.hasData {
                HealthEmptyState()
            } else {
                VStack(spacing: 8) {
                    header
                    switch page {
                    case .today: HealthTodayPage().transition(.tabSwitch)
                    case .week: HealthWeekPage().transition(.tabSwitch)
                    case .insights: HealthInsightsPage().transition(.tabSwitch)
                    }
                }
            }
        }
        .onAppear { health.refresh() }
    }

    /// Status of the source that's actually on: Garmin first (also while it syncs or errors), then Apple Health.
    private var statusText: String {
        let settings = Settings.shared
        if settings.garminEnabled, !(settings.appleHealthEnabled && !health.garminState.isReady && health.appleState.isReady) {
            return health.garminState.text
        }
        return settings.appleHealthEnabled ? health.appleState.text : ""
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(HealthSource.allCases.filter { health.today?.sources.contains($0) ?? false }) { s in
                    Label(s.title, systemImage: s.icon).labelStyle(.titleAndIcon)
                        .font(Theme.font(10, .semibold)).foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 7).frame(height: 20).background(Capsule().fill(Theme.surface))
                }
                Text(statusText)
                    .font(Theme.font(10)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(Page.allCases) { p in
                    Button { withAnimation(NotchViewModel.spring) { page = p } } label: {
                        Text(p.title).font(Theme.font(11, .semibold))
                            .foregroundStyle(page == p ? .black : .white.opacity(0.65))
                            .padding(.horizontal, 10).frame(height: 22)
                            .background(Capsule().fill(page == p ? Color.white : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(2).background(Capsule().fill(Color.white.opacity(0.05)))
            IconButton(systemName: "arrow.clockwise", size: 10, frame: 22, help: String(localized: "Обновить")) { health.refresh(force: true) }
        }
    }
}

// MARK: - Today

private struct HealthTodayPage: View {
    @EnvironmentObject var health: HealthService
    @EnvironmentObject var breathing: BreathingCoach

    var body: some View {
        let day = health.today ?? HealthDay(date: HealthDay.key(Date()))
        let yesterday = health.day(Date().addingTimeInterval(-86400))
        HStack(spacing: 10) {
            VStack(spacing: 8) {
                BodyBatteryGauge(level: health.latestBodyBattery?.v, charged: day.bbCharged, drained: day.bbDrained)
                StressNow(point: health.latestStress, heart: health.latestHeartRate)
            }
            .frame(width: 138)

            TodayChart(day: day, log: health.contextLog)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card(radius: 16)

            VStack(spacing: 6) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                    MetricTile(icon: "heart.fill", tint: .pink, title: String(localized: "Покой"),
                               value: day.restingHR.map { "\(Int($0))" }, unit: String(localized: "уд/мин"),
                               delta: delta(day.restingHR, yesterday?.restingHR), lowerIsBetter: true)
                    MetricTile(icon: "moon.zzz.fill", tint: .indigo, title: String(localized: "Сон"),
                               value: day.sleepSeconds.map { String(format: "%.1f", $0 / 3600) }, unit: day.sleepScore.map { String(localized: "ч · \(Int($0))") } ?? String(localized: "ч"),
                               delta: nil)
                    MetricTile(icon: "waveform.path.ecg", tint: .mint, title: "HRV",
                               value: day.hrvLastNight.map { "\(Int($0))" }, unit: String(localized: "мс"),
                               delta: delta(day.hrvLastNight, day.hrvWeekly), lowerIsBetter: false)
                    MetricTile(icon: "figure.walk", tint: .green, title: String(localized: "Шаги"),
                               value: day.steps.map { $0 >= 10000 ? String(format: String(localized: "%.1fк"), $0 / 1000) : "\(Int($0))" }, unit: "",
                               delta: nil)
                }
                PillButton(title: String(localized: "Подышать"), icon: "wind", tint: Color(red: 0.45, green: 0.8, blue: 1), prominent: true) {
                    breathing.start()
                }
                .frame(maxWidth: .infinity)
            }
            .frame(width: 176)
        }
    }

    private func delta(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }
}

private struct BodyBatteryGauge: View {
    let level: Double?
    let charged: Double?
    let drained: Double?

    var body: some View {
        let v = level ?? 0
        let tint = HealthAnalytics.batteryColor(v)
        HStack(spacing: 8) {
            // A person filled with energy up to the level; the surface waves gently.
            TimelineView(.animation(minimumInterval: 1 / 24, paused: level == nil)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                let figure = Image(systemName: "figure.stand").resizable().aspectRatio(contentMode: .fit)
                ZStack(alignment: .bottom) {
                    figure.foregroundStyle(Color.white.opacity(0.1))
                    Wave(level: v / 100, phase: t * 2.2, amplitude: level == nil ? 0 : 1.6)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                        .mask(figure)
                }
                .shadow(color: tint.opacity(0.45), radius: 6)
            }
            .frame(width: 32, height: 76)

            VStack(alignment: .leading, spacing: 1) {
                Text("Body Battery").font(Theme.font(9, .semibold)).foregroundStyle(Theme.tertiary)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Text(level.map { "\(Int($0))" } ?? "—")
                    .font(Theme.font(28, .bold)).monospacedDigit().foregroundStyle(level == nil ? Theme.tertiary : tint)
                    .contentTransition(.numericText())
                HStack(spacing: 6) {
                    if let charged { Label("+\(Int(charged))", systemImage: "arrow.up").foregroundStyle(.green) }
                    if let drained { Label("−\(Int(drained))", systemImage: "arrow.down").foregroundStyle(.orange) }
                }
                .labelStyle(TightLabel()).font(Theme.font(9, .bold)).monospacedDigit()
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .card(radius: 16)
    }
}

private struct Wave: Shape {
    var level: Double
    var phase: Double
    var amplitude: CGFloat

    var animatableData: Double {
        get { level }
        set { level = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let y = rect.maxY - rect.height * CGFloat(min(max(level, 0), 1))
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        for x in stride(from: rect.minX, through: rect.maxX, by: 2) {
            let k = Double(x / rect.width) * .pi * 2
            p.addLine(to: CGPoint(x: x, y: y + CGFloat(sin(k + phase)) * amplitude))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

private struct StressNow: View {
    let point: HealthPoint?
    let heart: HealthPoint?

    var body: some View {
        HStack(spacing: 8) {
            if let point {
                let level = HealthAnalytics.stressLevel(point.v)
                TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
                    // Faster, wider pulse the higher the stress.
                    let speed = 1.2 + point.v / 40
                    let k = (sin(ctx.date.timeIntervalSinceReferenceDate * speed * .pi) + 1) / 2
                    ZStack {
                        Circle().fill(level.color.opacity(0.18)).scaleEffect(1 + k * 0.25)
                        Ring(progress: point.v / 100, tint: level.color, lineWidth: 3)
                        Text("\(Int(point.v))").font(Theme.font(12, .bold)).monospacedDigit().foregroundStyle(.white)
                    }
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Стресс · \(level.title)")).font(Theme.font(11, .semibold)).foregroundStyle(level.color)
                    Text(ago(point.t)).font(Theme.font(9)).foregroundStyle(Theme.tertiary)
                }
            } else if let heart {
                Image(systemName: "heart.fill").foregroundStyle(.pink).font(.system(size: 18))
                    .symbolEffect(.pulse, options: .repeating)
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(localized: "Пульс \(Int(heart.v))")).font(Theme.font(12, .semibold)).foregroundStyle(.white)
                    Text(ago(heart.t)).font(Theme.font(9)).foregroundStyle(Theme.tertiary)
                }
            } else {
                Text(String(localized: "Нет свежих данных")).font(Theme.font(11)).foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .card(radius: 14)
    }

    private func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        return m < 1 ? String(localized: "только что") : (m < 60 ? String(localized: "\(m) мин назад") : String(localized: "\(m / 60) ч назад"))
    }
}

private struct TodayChart: View {
    let day: HealthDay
    let log: ContextLog

    struct Span: Identifiable {
        let id = UUID()
        let start: Date, end: Date
        let kind: String
        let color: Color
    }

    var body: some View {
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(6 * 3600)
        let end = max(Date(), start.addingTimeInterval(3600))
        let stress = day.stress.filter { $0.t >= start }
        let pulse = stress.isEmpty ? day.heartRate.filter { $0.t >= start } : []
        let battery = day.bodyBattery.filter { $0.t >= start }
        let spans = contextSpans(from: start, to: end)
        let away = awaySpans(from: start, to: end)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                legend(stress.isEmpty ? String(localized: "Пульс") : String(localized: "Стресс"), stress.isEmpty ? .pink : .orange)
                if !battery.isEmpty { legend("Body Battery", Color(red: 0.4, green: 0.75, blue: 1)) }
                Spacer()
                legend(String(localized: "Созвон"), .red); legend(String(localized: "Фокус"), .yellow); legend(String(localized: "Встреча"), .purple)
                if !away.isEmpty { legend(String(localized: "Не за Mac"), Color.white.opacity(0.35)) }
            }
            Chart {
                // Away from the Mac: a quiet band behind the lines.
                ForEach(away) { s in
                    RectangleMark(xStart: .value("from", s.start), xEnd: .value("to", s.end))
                        .foregroundStyle(Color.white.opacity(0.07))
                }
                ForEach(Array(stress.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("t", p.t), y: .value(String(localized: "Стресс"), p.v))
                        .foregroundStyle(LinearGradient(colors: [.red.opacity(0.55), .orange.opacity(0.35), .yellow.opacity(0.08)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                }
                ForEach(Array(pulse.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("t", p.t), y: .value(String(localized: "Пульс"), p.v), series: .value("s", "pulse"))
                        .foregroundStyle(.pink).lineStyle(StrokeStyle(lineWidth: 1.5)).interpolationMethod(.monotone)
                }
                ForEach(Array(battery.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("t", p.t), y: .value("BB", p.v), series: .value("s", "bb"))
                        .foregroundStyle(Color(red: 0.4, green: 0.75, blue: 1))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round)).interpolationMethod(.monotone)
                }
                RuleMark(x: .value("now", Date())).foregroundStyle(Color.white.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...(pulse.isEmpty ? 100 : max(120, (pulse.map(\.v).max() ?? 100) + 10)))
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                    AxisValueLabel(format: .dateTime.hour()).font(Theme.font(8)).foregroundStyle(Theme.tertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                    AxisValueLabel().font(Theme.font(8)).foregroundStyle(Theme.tertiary)
                }
            }
            .animation(.easeOut(duration: 0.6), value: day.stress.count)

            // What the Mac was doing, under the same time axis.
            GeometryReader { geo in
                let total = end.timeIntervalSince(start)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.05))
                    ForEach(away + spans) { s in
                        let x = geo.size.width * CGFloat(s.start.timeIntervalSince(start) / total)
                        let w = max(2, geo.size.width * CGFloat(s.end.timeIntervalSince(s.start) / total))
                        RoundedRectangle(cornerRadius: 2).fill(s.color.opacity(0.85))
                            .frame(width: w, height: 6).offset(x: x)
                            .help(s.kind)
                    }
                }
            }
            .frame(height: 6)
            .padding(.trailing, 22)
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(title).font(Theme.font(9, .medium)).foregroundStyle(Theme.secondary)
        }
    }

    /// Stretches of 5+ minutes without the Mac (no input and nothing playing, screen locked or asleep).
    /// Before NotchMate's first record of the day nothing is known, so nothing is shaded.
    private func awaySpans(from start: Date, to end: Date) -> [Span] {
        guard let first = log.firstMinute(onDayOf: start) else { return [] }
        let a = max(first, Int(start.timeIntervalSince1970 / 60)), b = Int(min(end, Date()).timeIntervalSince1970 / 60)
        guard a < b else { return [] }
        var spans: [Span] = []
        var runStart: Int?
        for minute in a...b {
            let present = log.minutes[minute].map { $0.contains(.atMac) || $0.contains(.call) } ?? false
            if !present, runStart == nil { runStart = minute }
            if (present || minute == b), let s = runStart {
                if minute - s >= 5 {
                    spans.append(Span(start: Date(timeIntervalSince1970: Double(s * 60)), end: Date(timeIntervalSince1970: Double(minute * 60)),
                                      kind: String(localized: "Не за Mac"), color: Color.white.opacity(0.3)))
                }
                runStart = nil
            }
        }
        return spans
    }

    /// Consecutive minutes of the same context merged into spans.
    private func contextSpans(from start: Date, to end: Date) -> [Span] {
        let kinds: [(MacContext, String, Color)] = [(.call, String(localized: "Созвон"), .red), (.meeting, String(localized: "Встреча"), .purple), (.focus, String(localized: "Фокус"), .yellow)]
        var spans: [Span] = []
        let a = Int(start.timeIntervalSince1970 / 60), b = Int(end.timeIntervalSince1970 / 60)
        for (flag, title, color) in kinds {
            var runStart: Int?
            for minute in a...b {
                let on = log.minutes[minute]?.contains(flag) ?? false
                if on, runStart == nil { runStart = minute }
                if (!on || minute == b), let s = runStart {
                    spans.append(Span(start: Date(timeIntervalSince1970: Double(s * 60)), end: Date(timeIntervalSince1970: Double(minute * 60)),
                                      kind: title, color: color))
                    runStart = nil
                }
            }
        }
        return spans
    }
}

private struct MetricTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String?
    let unit: String
    let delta: Double?
    var lowerIsBetter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                Text(title).font(Theme.font(9, .semibold)).foregroundStyle(Theme.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—").font(Theme.font(16, .bold)).monospacedDigit().foregroundStyle(value == nil ? Theme.tertiary : .white)
                Text(unit).font(Theme.font(8, .medium)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            if let delta, abs(delta) >= 1 {
                let good = lowerIsBetter ? delta < 0 : delta > 0
                Label("\(delta > 0 ? "+" : "")\(Int(delta))", systemImage: delta > 0 ? "arrow.up.right" : "arrow.down.right")
                    .labelStyle(TightLabel()).font(Theme.font(8, .bold)).foregroundStyle(good ? .green : .orange)
            } else {
                Text(" ").font(Theme.font(8))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) { configuration.icon; configuration.title }
    }
}

// MARK: - Week

private struct HealthWeekPage: View {
    @EnvironmentObject var health: HealthService

    var body: some View {
        let week = health.recent(7)
        HStack(spacing: 10) {
            chartCard(String(localized: "Сон"), icon: "moon.zzz.fill", tint: .indigo, summary: avgText(week.compactMap(\.sleepSeconds)) { HealthAnalytics.hours($0) }) {
                Chart {
                    ForEach(week, id: \.date) { d in
                        let x = label(d.date)
                        ForEach(stages(d), id: \.0) { name, secs, color in
                            BarMark(x: .value(String(localized: "День"), x), y: .value(String(localized: "ч"), secs / 3600))
                                .foregroundStyle(color).cornerRadius(2)
                                .position(by: .value("stage", name), axis: .vertical)
                        }
                        if let score = d.sleepScore {
                            PointMark(x: .value(String(localized: "День"), x), y: .value(String(localized: "ч"), (d.sleepSeconds ?? 0) / 3600 + 0.6))
                                .symbolSize(0)
                                .annotation(position: .overlay) {
                                    Text("\(Int(score))").font(Theme.font(8, .bold)).foregroundStyle(Theme.secondary)
                                }
                        }
                    }
                    RuleMark(y: .value(String(localized: "норма"), 7)).foregroundStyle(Color.white.opacity(0.2)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(Theme.font(8)).foregroundStyle(Theme.tertiary) } }
            }

            let hasStress = week.contains { $0.stressAvg != nil }
            chartCard(hasStress ? String(localized: "Стресс и Body Battery") : String(localized: "Пульс покоя"), icon: hasStress ? "gauge.with.dots.needle.50percent" : "heart.fill",
                      tint: hasStress ? .orange : .pink,
                      summary: hasStress ? avgText(week.compactMap(\.stressAvg)) { String(localized: "средний \(Int($0))") } : avgText(week.compactMap(\.restingHR)) { String(localized: "\(Int($0)) уд/мин") }) {
                Chart {
                    ForEach(week, id: \.date) { d in
                        let x = label(d.date)
                        if hasStress {
                            if let lo = d.bbLow, let hi = d.bbHigh {
                                BarMark(x: .value(String(localized: "День"), x), yStart: .value("min", lo), yEnd: .value("max", hi), width: .fixed(14))
                                    .foregroundStyle(Color(red: 0.4, green: 0.75, blue: 1).opacity(0.25)).cornerRadius(4)
                            }
                            if let s = d.stressAvg {
                                BarMark(x: .value(String(localized: "День"), x), y: .value(String(localized: "Стресс"), s), width: .fixed(6))
                                    .foregroundStyle(HealthAnalytics.stressLevel(s).color).cornerRadius(3)
                            }
                        } else if let r = d.restingHR {
                            LineMark(x: .value(String(localized: "День"), x), y: .value(String(localized: "Покой"), r)).foregroundStyle(.pink).interpolationMethod(.monotone)
                            PointMark(x: .value(String(localized: "День"), x), y: .value(String(localized: "Покой"), r)).foregroundStyle(.pink).symbolSize(18)
                        }
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks { _ in AxisValueLabel().font(Theme.font(8)).foregroundStyle(Theme.tertiary) } }
            }

            VStack(spacing: 6) {
                trendTile(String(localized: "Пульс покоя"), week.compactMap(\.restingHR), unit: String(localized: "уд/мин"), tint: .pink, lowerIsBetter: true)
                trendTile(String(localized: "HRV ночью"), week.compactMap(\.hrvLastNight), unit: String(localized: "мс"), tint: .mint, lowerIsBetter: false)
                trendTile(String(localized: "Шаги"), week.compactMap(\.steps), unit: String(localized: "в день"), tint: .green, lowerIsBetter: false)
            }
            .frame(width: 150)
        }
    }

    private func chartCard<C: View>(_ title: String, icon: String, tint: Color, summary: String, @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(tint)
                Text(title).font(Theme.font(11, .semibold)).foregroundStyle(.white)
                Spacer()
                Text(summary).font(Theme.font(10, .medium)).foregroundStyle(Theme.secondary)
            }
            chart()
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 16)
    }

    private func trendTile(_ title: String, _ values: [Double], unit: String, tint: Color, lowerIsBetter: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(Theme.font(9, .semibold)).foregroundStyle(Theme.tertiary)
                Spacer()
                if let first = values.first, let last = values.last, values.count >= 3, abs(last - first) >= 1 {
                    let good = lowerIsBetter ? last < first : last > first
                    Image(systemName: last > first ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(good ? .green : .orange)
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                Text(HealthAnalytics.avg(values).map { $0 >= 10000 ? String(format: String(localized: "%.1fк"), $0 / 1000) : "\(Int($0))" } ?? "—")
                    .font(Theme.font(15, .bold)).monospacedDigit().foregroundStyle(.white)
                Text(unit).font(Theme.font(8)).foregroundStyle(Theme.tertiary)
                Spacer(minLength: 0)
                Sparkline(values: values, tint: tint).frame(width: 46, height: 16)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .card(radius: 12)
    }

    private func stages(_ d: HealthDay) -> [(String, Double, Color)] {
        if d.deepSeconds == nil && d.remSeconds == nil, let total = d.sleepSeconds { return [(String(localized: "Сон"), total, .indigo)] }
        return [(String(localized: "Глубокий"), d.deepSeconds ?? 0, Color(red: 0.3, green: 0.3, blue: 0.85)),
                (String(localized: "Лёгкий"), d.lightSeconds ?? 0, Color(red: 0.45, green: 0.55, blue: 1)),
                ("REM", d.remSeconds ?? 0, Color(red: 0.75, green: 0.5, blue: 1)),
                (String(localized: "Пробуждения"), d.awakeSeconds ?? 0, Color.white.opacity(0.35))]
    }

    private func label(_ key: String) -> String {
        guard let d = HealthDay.date(key) else { return key }
        let f = DateFormatter(); f.locale = AppLanguage.locale; f.dateFormat = "EEEEEE"
        return f.string(from: d)
    }

    private func avgText(_ v: [Double], _ fmt: (Double) -> String) -> String {
        HealthAnalytics.avg(v).map(fmt) ?? ""
    }
}

private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if values.count >= 2, let lo = values.min(), let hi = values.max() {
                let range = max(hi - lo, 1)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                                         y: geo.size.height * (1 - CGFloat((v - lo) / range)))
                        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Insights

private struct HealthInsightsPage: View {
    @EnvironmentObject var health: HealthService
    @EnvironmentObject var breathing: BreathingCoach
    @State private var appeared = false
    @AppStorage("healthLoadsByApps") private var byApps = false

    var body: some View {
        let (metric, loads, base) = byApps
            ? HealthAnalytics.activityLoads(days: health.recent(14), log: health.contextLog)
            : HealthAnalytics.contextLoads(days: health.recent(14), log: health.contextLog)
        let insights = HealthAnalytics.insights(service: health, breathing: breathing)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(String(localized: "Что нагружает")).font(Theme.font(11, .semibold)).foregroundStyle(.white)
                    HStack(spacing: 2) {
                        ForEach([false, true], id: \.self) { apps in
                            Button { withAnimation(.easeOut(duration: 0.2)) { byApps = apps } } label: {
                                Text(apps ? String(localized: "Приложения") : String(localized: "Занятия")).font(Theme.font(9, .semibold))
                                    .foregroundStyle(byApps == apps ? Color.black : Theme.secondary)
                                    .padding(.horizontal, 6).frame(height: 16)
                                    .background(Capsule().fill(byApps == apps ? Color.white.opacity(0.85) : Color.clear))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                    .padding(2).background(Capsule().fill(Color.white.opacity(0.06)))
                    Spacer()
                    if let base {
                        Text("≈ \(Int(base))").font(Theme.font(9)).foregroundStyle(Theme.tertiary)
                            .help(String(localized: "Средний \(metric.title), пока вы за Mac"))
                    }
                }
                if loads.isEmpty {
                    Spacer()
                    Text(byApps ? String(localized: "Приложения и сайты начали записываться — нужно немного данных с часов") : String(localized: "Нужно пару дней данных с часов, пока NotchMate открыта"))
                        .font(Theme.font(11)).foregroundStyle(Theme.tertiary).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    let span = max(loads.map { abs($0.delta) }.max() ?? 1, 5)
                    ForEach(Array(loads.prefix(byApps ? 7 : 6).enumerated()), id: \.element.id) { i, l in
                        HStack(spacing: 6) {
                            Image(systemName: l.icon).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary).frame(width: 14)
                            Text(l.title).font(Theme.font(10, .medium)).foregroundStyle(.white.opacity(0.85)).frame(width: 96, alignment: .leading).lineLimit(1)
                            GeometryReader { geo in
                                let mid = geo.size.width / 2
                                let w = mid * CGFloat(abs(l.delta) / span) * (appeared ? 1 : 0)
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1).offset(x: mid)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(l.delta > 0 ? Color.orange : Color.green)
                                        .frame(width: w, height: 8)
                                        .offset(x: l.delta > 0 ? mid : mid - w)
                                }
                                .frame(maxHeight: .infinity)
                                .animation(.spring(response: 0.6, dampingFraction: 0.8).delay(Double(i) * 0.06), value: appeared)
                            }
                            Text("\(l.delta > 0 ? "+" : "")\(Int(l.delta))").font(Theme.font(10, .bold)).monospacedDigit()
                                .foregroundStyle(l.delta > 0 ? .orange : .green).frame(width: 28, alignment: .trailing)
                        }
                        .frame(height: 20)
                        .help(String(localized: "\(l.title): \(metric.title) ≈ \(Int(l.value)) за \(l.minutes) мин"))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .frame(width: 290)
            .frame(maxHeight: .infinity)
            .card(radius: 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(Array(insights.enumerated()), id: \.element.id) { i, item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.icon).font(.system(size: 12, weight: .bold)).foregroundStyle(item.tint)
                                .frame(width: 24, height: 24).background(Circle().fill(item.tint.opacity(0.15)))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(Theme.font(11, .semibold)).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                                if !item.detail.isEmpty {
                                    Text(item.detail).font(Theme.font(10)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .card(radius: 12)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 8)
                        .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.05 + Double(i) * 0.05), value: appeared)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear { appeared = true }
    }
}

// MARK: - Empty & breathing

private struct HealthEmptyState: View {
    @EnvironmentObject var health: HealthService
    @EnvironmentObject var breathing: BreathingCoach

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "heart.text.square.fill").font(.system(size: 40)).foregroundStyle(.pink)
                .symbolEffect(.pulse, options: .repeating)
            VStack(alignment: .leading, spacing: 6) {
                Text(health.isEnabled ? String(localized: "Жду данные") : String(localized: "Подключите Garmin или Apple Health"))
                    .font(Theme.font(16, .bold)).foregroundStyle(.white)
                Text(health.isEnabled
                     ? "Garmin: \(Settings.shared.garminEnabled ? health.garminState.text : String(localized: "выключен")) · Apple Health: \(Settings.shared.appleHealthEnabled ? health.appleState.text : String(localized: "выключен"))"
                     : String(localized: "Стресс, Body Battery, сон и пульс — и как на них влияют созвоны, фокус и встречи."))
                    .font(Theme.font(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PillButton(title: String(localized: "Настройки"), icon: "gearshape.fill", prominent: true) {
                        NotificationCenter.default.post(name: .notchMateOpenSettings, object: nil)
                    }
                    PillButton(title: String(localized: "Подышать"), icon: "wind") { breathing.start() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 20)
    }
}

private struct BreathingPanel: View {
    @EnvironmentObject var breathing: BreathingCoach
    private let tint = Color(red: 0.45, green: 0.8, blue: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let s = breathing.state(at: ctx.date)
            HStack(spacing: 24) {
                BreathingOrb(fullness: s.fullness, tint: tint, size: 150)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(s.phase.title).font(Theme.font(18, .bold)).foregroundStyle(.white)
                            Text("\(s.secondsLeftInPhase)").font(Theme.font(13, .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(width: 180, height: 180)
                VStack(alignment: .leading, spacing: 8) {
                    Text(breathing.pattern.title).font(Theme.font(17, .bold)).foregroundStyle(.white)
                    Text(breathing.pattern.subtitle).font(Theme.font(11)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 6) {
                        Ring(progress: 1 - s.remaining / breathing.duration, tint: tint, lineWidth: 3).frame(width: 16, height: 16)
                        Text(String(localized: "осталось ") + FocusTimer.format(s.remaining)).font(Theme.font(12, .semibold)).monospacedDigit().foregroundStyle(tint)
                    }
                    PillButton(title: String(localized: "Закончить"), icon: "stop.fill") { breathing.stop() }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card(radius: 20)
    }
}

/// Soft glowing orb: grows on the inhale, shrinks on the exhale, with slowly rotating halo rings.
struct BreathingOrb: View {
    let fullness: Double
    let tint: Color
    var size: CGFloat

    var body: some View {
        let k = CGFloat(0.55 + 0.45 * fullness)
        ZStack {
            ForEach(0..<3) { i in
                Circle()
                    .stroke(tint.opacity(0.18 - Double(i) * 0.05), lineWidth: 1)
                    .frame(width: size * (k + CGFloat(i + 1) * 0.1 * CGFloat(fullness)), height: size * (k + CGFloat(i + 1) * 0.1 * CGFloat(fullness)))
            }
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.95), tint.opacity(0.35), tint.opacity(0.05)],
                                     center: .center, startRadius: 0, endRadius: size * k / 2))
                .frame(width: size * k, height: size * k)
                .shadow(color: tint.opacity(0.35 + 0.35 * fullness), radius: 10 + 20 * fullness)
        }
    }
}

// MARK: - Collapsed notch

/// Breathing guide right under the face while the notch is closed.
struct BreathingNotchOverlay: View {
    @EnvironmentObject var breathing: BreathingCoach
    private let tint = Color(red: 0.45, green: 0.8, blue: 1)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let s = breathing.state(at: ctx.date)
            HStack(spacing: 10) {
                BreathingOrb(fullness: s.fullness, tint: tint, size: 38).frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(s.phase.title) · \(s.secondsLeftInPhase)").font(Theme.font(13, .bold)).foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text(String(localized: "осталось ") + FocusTimer.format(s.remaining)).font(Theme.font(10, .medium)).monospacedDigit().foregroundStyle(tint)
                }
                Spacer(minLength: 0)
                Button { breathing.stop() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(width: 20, height: 20).background(Circle().fill(Theme.surface))
                }
                .buttonStyle(PressableStyle())
            }
            .padding(.horizontal, 14)
            .frame(height: 56)
        }
    }
}
