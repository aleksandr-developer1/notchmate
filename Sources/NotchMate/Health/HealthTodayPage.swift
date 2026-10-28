import Charts
import SwiftUI

// MARK: - Today

struct HealthTodayPage: View {
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

struct BodyBatteryGauge: View {
    let level: Double?
    let charged: Double?
    let drained: Double?

    var body: some View {
        let v = level ?? 0
        let tint = HealthAnalytics.batteryColor(v)
        HStack(spacing: 8) {
            // A person filled with energy up to the level; the surface waves gently.
            EnergyAnimation(minimumInterval: 1 / 24, paused: level == nil) { ctx in
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

struct Wave: Shape {
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

struct StressNow: View {
    let point: HealthPoint?
    let heart: HealthPoint?

    var body: some View {
        HStack(spacing: 8) {
            if let point {
                let level = HealthAnalytics.stressLevel(point.v)
                EnergyAnimation(minimumInterval: 1 / 20) { ctx in
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

struct TodayChart: View {
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

struct MetricTile: View {
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

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) { configuration.icon; configuration.title }
    }
}
