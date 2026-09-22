import AppKit
import SwiftUI

struct MediaView: View {
    let ns: Namespace.ID
    @EnvironmentObject var player: NowPlayingService
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        HStack(spacing: 12) {
            if player.track != nil {
                PlayerCard(ns: ns)
            } else {
                EmptyPlayerCard()
            }
            WidgetColumn().frame(width: 132)
        }
    }
}

private struct PlayerCard: View {
    let ns: Namespace.ID
    @EnvironmentObject var player: NowPlayingService
    @EnvironmentObject var volume: SystemVolume
    @EnvironmentObject var tempo: TempoService
    @State private var scrubPreview: Double?
    @State private var artHover = false

    var body: some View {
        let track = player.track!
        HStack(spacing: 16) {
            // Artwork
            ZStack(alignment: .bottomTrailing) {
                ArtworkView(image: player.artwork, size: 134, radius: 16)
                    .matchedGeometryEffect(id: "artwork", in: ns)
                    .background { ArtworkGlow(image: player.artwork, accent: player.accent, size: 134, isPlaying: track.isPlaying) }
                    .scaleEffect(track.isPlaying ? 1 : 0.94)
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: track.isPlaying)
                    .overlay {
                        if artHover {
                            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.35))
                                .overlay(Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 26)).foregroundStyle(.white))
                                .transition(.opacity)
                        }
                    }
                if !track.bundleID.isEmpty {
                    AppIconView(bundleID: track.bundleID, size: 26)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                        .offset(x: 6, y: 6)
                }
            }
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { artHover = h } }
            .onTapGesture { player.openSourceApp() }
            .help("Открыть \(player.sourceAppName)")

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(text: track.title, font: Theme.font(16, .bold), color: .white)
                        Text(track.artist.isEmpty ? player.sourceAppName : track.artist)
                            .font(Theme.font(13, .medium))
                            .foregroundStyle(player.accent)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    DiscoButton()
                        .padding(.top, 1)
                    TapTempoButton()
                        .padding(.top, 1)
                    if track.isLiked == true {
                        Image(systemName: "heart.fill").font(.system(size: 12)).foregroundStyle(.pink)
                            .padding(.top, 3)
                    }
                }

                Spacer(minLength: 6)

                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let elapsed = scrubPreview.map { $0 * track.duration } ?? track.elapsed(at: ctx.date)
                    VStack(spacing: 2) {
                        Scrubber(value: track.duration > 0 ? elapsed / track.duration : 0, tint: player.accent,
                                 onCommit: { v in player.seek(to: v * track.duration) },
                                 onDragChanged: { scrubPreview = $0 })
                        HStack {
                            Text(formatTime(elapsed))
                            Spacer()
                            Text(track.duration > 0 ? "-" + formatTime(track.duration - elapsed) : "")
                        }
                        .font(Theme.font(10, .medium)).monospacedDigit()
                        .foregroundStyle(Theme.tertiary)
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    IconButton(systemName: "shuffle", size: 11, frame: 26,
                               tint: (track.shuffle ?? 1) > 1 ? player.accent : .white.opacity(0.7), help: "Перемешать") {
                        player.send(.toggleShuffle)
                    }
                    IconButton(systemName: "backward.fill", size: 15, frame: 34, help: "Назад") { player.send(.previous) }
                    PlayPauseButton(isPlaying: track.isPlaying, tint: player.accent) { player.send(.toggle) }
                    IconButton(systemName: "forward.fill", size: 15, frame: 34, help: "Вперёд") { player.send(.next) }
                    IconButton(systemName: (track.repeatMode ?? 1) == 2 ? "repeat.1" : "repeat", size: 11, frame: 26,
                               tint: (track.repeatMode ?? 1) > 1 ? player.accent : .white.opacity(0.7), help: "Повтор") {
                        player.send(.toggleRepeat)
                    }
                    Spacer(minLength: 8)
                    VolumeControl(tint: player.accent)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Ambient glow from artwork
            ZStack {
                if let art = player.artwork {
                    Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
                        .blur(radius: 60).opacity(0.42).saturation(1.5)
                    // Keeps text readable over bright covers.
                    LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.35)], startPoint: .leading, endPoint: .trailing)
                }
                LinearGradient(colors: [player.accent.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 0.5))
            .animation(.easeInOut(duration: 0.6), value: player.accent)
            // The .fill artwork is far taller than the card; clipShape only clips drawing, not hit-testing,
            // so without this it swallows clicks on the tab bar and header above the card.
            .allowsHitTesting(false)
        }
    }
}

/// Soft blurred copy of the cover underneath it; on a known tempo it breathes with the beat.
private struct ArtworkGlow: View {
    let image: NSImage?
    let accent: Color
    let size: CGFloat
    let isPlaying: Bool
    @EnvironmentObject var tempo: TempoService

    var body: some View {
        let live = isPlaying && tempo.tempo != nil
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !isPlaying)) { ctx in
            // Sharp attack on the beat, exponential decay until the next one.
            let pulse = !isPlaying ? 0 : tempo.audio.isLive ? Double(tempo.audio.glowLevels().kick)
                : live ? tempo.beats(at: ctx.date).map { exp(-4 * ($0 - $0.rounded(.down))) } ?? 0 : 0
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                        .blur(radius: 22 + pulse * 6)
                        .saturation(1.6)
                        .opacity((isPlaying ? 0.75 : 0.4) + pulse * 0.2)
                } else {
                    RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).fill(accent)
                        .blur(radius: 22).opacity(0.45)
                }
            }
            .scaleEffect((isPlaying ? 1.02 : 0.9) + pulse * 0.05)
            .offset(y: 8)
        }
        .animation(.easeInOut(duration: 0.5), value: isPlaying)
        .allowsHitTesting(false)
    }
}

/// Toggles disco mode: the glow spreads from the notch around the whole screen frame.
private struct DiscoButton: View {
    @EnvironmentObject var disco: DiscoMode
    @EnvironmentObject var player: NowPlayingService

    var body: some View {
        Button { disco.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: disco.isOn ? "sparkles" : "party.popper.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text("Диско")
            }
            .font(Theme.font(10, .bold))
            .foregroundStyle(disco.isOn ? AnyShapeStyle(player.accent)
                                        : AnyShapeStyle(Color.white.opacity(0.55)))
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(.white.opacity(disco.isOn ? 0.16 : 0.07)))
            .overlay {
                if disco.isOn {
                    Capsule().strokeBorder(player.accent.opacity(0.8), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .animation(.easeOut(duration: 0.2), value: disco.isOn)
        .help(disco.isOn ? "Выключить режим дискотеки" : "Режим дискотеки: свечение по рамке экрана")
    }
}

/// Tap along with the music when the catalogue has no BPM for the track.
private struct TapTempoButton: View {
    @EnvironmentObject var tempo: TempoService
    @EnvironmentObject var player: NowPlayingService

    var body: some View {
        let counting = tempo.tapCount > 0
        Button { tempo.tap() } label: {
            HStack(spacing: 3) {
                Image(systemName: "metronome.fill").font(.system(size: 10, weight: .semibold))
                if counting {
                    Text("\(tempo.tapCount)").monospacedDigit()
                } else if let t = tempo.tempo {
                    Text("\(Int(t.bpm.rounded()))").monospacedDigit()
                }
            }
            .font(Theme.font(10, .bold))
            .foregroundStyle(counting || tempo.tempo?.source == .tapped ? player.accent : .white.opacity(0.55))
            .padding(.horizontal, 6).frame(height: 18)
            .background(Capsule().fill(.white.opacity(counting ? 0.16 : 0.07)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tempo.tempo == nil ? "Темп определяется по звуку. Можно простучать в такт (4+ раз)"
                                 : "Темп \(Int(tempo.tempo!.bpm.rounded())) BPM. Стучи в такт, чтобы поправить")
    }
}

private struct PlayPauseButton: View {
    let isPlaying: Bool
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(hovering ? 1 : 0.92))
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .offset(x: isPlaying ? 0 : 1.5)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 40, height: 40)
            .shadow(color: tint.opacity(hovering ? 0.6 : 0.25), radius: hovering ? 12 : 6)
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(isPlaying ? "Пауза" : "Играть")
    }
}

private struct VolumeControl: View {
    let tint: Color
    @EnvironmentObject var volume: SystemVolume

    var body: some View {
        HStack(spacing: 6) {
            Button { volume.setMuted(!volume.isMuted) } label: {
                Image(systemName: volumeIcon).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary).frame(width: 16)
                    .contentTransition(.symbolEffect(.replace))
            }.buttonStyle(.plain)
            Scrubber(value: volume.isMuted ? 0 : Double(volume.volume), tint: .white.opacity(0.85),
                     onCommit: { volume.set(Float($0)) },
                     onDragChanged: { if let v = $0 { volume.set(Float(v)) } })
                .frame(width: 70)
        }
    }

    private var volumeIcon: String {
        if volume.isMuted || volume.volume < 0.01 { return "speaker.slash.fill" }
        if volume.volume < 0.33 { return "speaker.wave.1.fill" }
        if volume.volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct EmptyPlayerCard: View {
    @EnvironmentObject var player: NowPlayingService

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.yandex.opacity(0.35), Color.orange.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform").font(.system(size: 40, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .symbolEffect(.pulse, options: .repeating)
            }
            .frame(width: 134, height: 134)

            VStack(alignment: .leading, spacing: 6) {
                Text("Тишина").font(Theme.font(18, .bold)).foregroundStyle(.white)
                Text(player.isAvailable ? "Включите музыку — управление появится здесь" : "Модуль Now Playing недоступен")
                    .font(Theme.font(12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    PillButton(title: "Яндекс Музыка", icon: "play.fill", tint: Theme.yandex, prominent: true) {
                        NowPlayingService.launchYandexMusic()
                    }
                    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") != nil {
                        PillButton(title: "Spotify", tint: .green) {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                            }
                        }
                    }
                    IconButton(systemName: "play.fill", size: 12, frame: 28, filled: true, help: "Продолжить последнее") {
                        player.send(.play)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, 8)
        }
        .padding(10)
        .card(radius: 20)
    }
}

// MARK: - Widgets

private struct WidgetColumn: View {
    @EnvironmentObject var focus: FocusTimer
    @EnvironmentObject var obsidian: ObsidianService
    @EnvironmentObject var vm: NotchViewModel

    var body: some View {
        VStack(spacing: 8) {
            WidgetTile(action: {
                if focus.phase == .idle { focus.start(minutes: 25) } else { vm.select(NotchTab.focus) }
            }) {
                HStack(spacing: 10) {
                    ZStack {
                        Ring(progress: focus.isActive ? focus.progress : 0, tint: .orange, lineWidth: 3)
                        Image(systemName: focus.phase == .running ? "pause.fill" : "timer")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(focus.isActive ? FocusTimer.format(focus.remaining) : "25:00")
                            .font(Theme.font(15, .bold)).monospacedDigit().foregroundStyle(.white)
                            .contentTransition(.numericText(countsDown: true))
                        Text(focus.isActive ? focus.label : "Фокус").font(Theme.font(10, .medium)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            WidgetTile(action: { obsidian.openDailyNote() }) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.obsidian.opacity(0.22))
                        Text(Date(), format: .dateTime.day()).font(Theme.font(14, .bold)).foregroundStyle(Theme.obsidian)
                    }
                    .frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Date(), format: .dateTime.weekday(.wide).locale(Locale(identifier: "ru_RU")))
                            .font(Theme.font(13, .bold)).foregroundStyle(.white).lineLimit(1)
                        Text("Заметка дня").font(Theme.font(10, .medium)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct WidgetTile<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .card(radius: 16, fill: hovering ? Theme.surfaceHover : Theme.surface)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

/// Single-line text that gently scrolls when it doesn't fit.
struct MarqueeText: View {
    let text: String
    let font: Font
    let color: Color
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth - geo.size.width
            TimelineView(.animation(minimumInterval: 1 / 30, paused: overflow <= 0)) { ctx in
                let cycle = Double(overflow) / 22 + 4 // seconds: scroll + pauses
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: max(cycle * 2, 1))
                let scrollTime = cycle - 4
                let phase: Double = {
                    if t < 2 { return 0 }
                    if t < 2 + scrollTime { return (t - 2) / scrollTime }
                    if t < cycle + 2 { return 1 }
                    if t < cycle + 2 + scrollTime { return 1 - (t - cycle - 2) / scrollTime }
                    return 0
                }()
                Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
                    .background(GeometryReader { g in Color.clear.onAppear { textWidth = g.size.width }.onChange(of: text) { _, _ in textWidth = g.size.width } })
                    .offset(x: overflow > 0 ? -overflow * phase : 0)
            }
            .frame(width: geo.size.width, alignment: .leading)
            .clipped()
            .mask(
                LinearGradient(stops: overflow > 0
                    ? [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)]
                    : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
                    startPoint: .leading, endPoint: .trailing)
            )
        }
        .frame(height: 20)
    }
}

extension Text {
    func fixedSize() -> some View { self.fixedSize(horizontal: true, vertical: false) }
}
