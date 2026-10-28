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
        if settings.pluginEnabled(.garmin), !(settings.pluginEnabled(.appleHealth) && !health.garminState.isReady && health.appleState.isReady) {
            return health.garminState.text
        }
        return settings.pluginEnabled(.appleHealth) ? health.appleState.text : ""
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
                     ? "Garmin: \(Settings.shared.pluginEnabled(.garmin) ? health.garminState.text : String(localized: "выключен")) · Apple Health: \(Settings.shared.pluginEnabled(.appleHealth) ? health.appleState.text : String(localized: "выключен"))"
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
        EnergyAnimation(minimumInterval: 1 / 30) { ctx in
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
        EnergyAnimation(minimumInterval: 1 / 30) { ctx in
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
