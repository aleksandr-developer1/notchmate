import Charts
import SwiftUI

// MARK: - Week

struct HealthWeekPage: View {
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

struct Sparkline: View {
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

struct HealthInsightsPage: View {
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
