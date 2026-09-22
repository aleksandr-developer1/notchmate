import AppKit
import SwiftUI

/// Disco mode: a glow in the cover's color runs out of the notch along the whole screen frame and pulses with the music.
@MainActor
final class DiscoMode: ObservableObject {
    @Published private(set) var isOn = false
    /// Mac left alone while disco plays: the screen dims, a disco ball drops from the notch.
    @Published private(set) var party = false

    static let partyEnterDuration = 2.2
    static let partyLeaveDuration = 0.7

    static let partyDelay: TimeInterval = 30
    /// Players whose "now playing" is usually a video — don't cover a film with a disco ball.
    private static let videoSources: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox",
        "com.microsoft.edgemac", "ru.yandex.desktop.yandex-browser", "com.operasoftware.Opera", "com.brave.Browser",
        "com.apple.TV", "org.videolan.vlc", "com.colliderli.iina", "com.apple.QuickTimePlayerX",
    ]

    private var windows: [NSPanel] = []
    private var hideWork: DispatchWorkItem?
    private weak var env: AppEnvironment?
    private var idleTimer: Timer?
    /// Turned on by idleness rather than the button: goes away together with the party.
    private var autoStarted = false

    func start(env: AppEnvironment) {
        self.env = env
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isOn else { return }
                self.closeWindows()
                self.showWindows()
            }
        }
    }

    func toggle() {
        autoStarted = false
        isOn ? turnOff() : turnOn()
    }

    func turnOn() {
        guard !isOn else { return }
        hideWork?.cancel()
        hideWork = nil
        if windows.isEmpty { showWindows() }
        // Next runloop: the glow view must appear collapsed first so the spread animates.
        DispatchQueue.main.async { self.isOn = true }
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        party = false
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.closeWindows() } }
        hideWork = work
        // Let the ball go back up too.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(DiscoGlowView.retractDuration, Self.partyLeaveDuration) + 0.1,
                                      execute: work)
    }

    private func checkIdle() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard let env else { return }
        let track = env.nowPlaying.track
        let playing = track?.isPlaying == true

        if !isOn {
            // Auto disco: the frame spreads first, the ball drops once it has run around the screen.
            guard env.settings.autoDisco, playing, idle >= Self.partyDelay, !env.companion.inCall,
                  !Self.videoSources.contains(track?.bundleID ?? "") else { return }
            autoStarted = true
            turnOn()
            DispatchQueue.main.asyncAfter(deadline: .now() + DiscoGlowView.spreadDuration * 0.8) { [weak self] in
                guard let self, self.isOn, self.autoStarted else { return }
                self.party = true
            }
            return
        }

        if !party, playing, idle >= Self.partyDelay {
            party = true
        } else if (party || autoStarted), idle < 1 || !playing {
            party = false
            guard autoStarted else { return }
            // Let the ball go back up, then fold the frame into the notch.
            autoStarted = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.autoStarted, !self.party else { return }
                self.turnOff()
            }
        }
    }

    private func showWindows() {
        guard let env else { return }
        let primary = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.isFloatingPanel = true
            // Above the menu bar, just under the notch panel (statusBar + 2).
            panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            panel.animationBehavior = .none
            let root = DiscoGlowView(cornerRadius: screen.safeAreaInsets.top > 0 ? 12 : 0, isPrimary: screen == primary)
                .environmentObject(self)
                .environmentObject(env.tempo)
                .environmentObject(env.nowPlaying)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
            panel.contentView = hosting
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            windows.append(panel)
        }
    }

    private func closeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

/// Screen border path that starts at the top center (the notch) and runs clockwise back to it,
/// so trimming both ends makes the light spread from the notch down both sides and meet at the bottom.
private struct ScreenFrameShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + r), radius: r)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - r, y: rect.maxY), radius: r)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - r), radius: r)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + r, y: rect.minY), radius: r)
        p.closeSubpath()
        return p
    }
}

/// Both arms of the glow: `progress` 0 → nothing, 1 → the full frame.
private struct SpreadingFrame: Shape {
    let cornerRadius: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let base = ScreenFrameShape(cornerRadius: cornerRadius).path(in: rect)
        let half = max(0, min(progress, 1)) / 2
        var p = base.trimmedPath(from: 0, to: half)
        p.addPath(base.trimmedPath(from: 1 - half, to: 1))
        return p
    }
}

struct DiscoGlowView: View {
    static let spreadDuration = 1.4
    static let retractDuration = 0.8

    let cornerRadius: CGFloat
    let isPrimary: Bool
    @EnvironmentObject var disco: DiscoMode
    @EnvironmentObject var tempo: TempoService
    @EnvironmentObject var player: NowPlayingService
    @State private var progress: CGFloat = 0

    var body: some View {
        ZStack {
            PartyScene(isPrimary: isPrimary)
            frameGlow
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var frameGlow: some View {
        let playing = player.track?.isPlaying == true
        return TimelineView(.animation(minimumInterval: 1 / 30, paused: !disco.isOn && progress == 0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = tempo.beatPulse(at: ctx.date, playing: playing)
            let rotation = Angle.degrees((t * (playing ? 60 : 20)).truncatingRemainder(dividingBy: 360))
            // Cover color with brighter and dimmer stretches running around the frame.
            let accent = player.accent
            let gradient = AngularGradient(
                colors: [accent, accent.opacity(0.45), accent, accent.opacity(0.7), accent],
                center: .center, angle: rotation)
            let frame = SpreadingFrame(cornerRadius: cornerRadius, progress: progress)
            let brightness = (playing ? 0.75 : 0.45) + pulse * 0.25

            ZStack {
                // Wide soft halo, breathes with the kick.
                frame.stroke(gradient, style: StrokeStyle(lineWidth: 28 + pulse * 22, lineCap: .round))
                    .blur(radius: 26 + pulse * 10)
                    .opacity(brightness * 0.9)
                // Mid glow.
                frame.stroke(gradient, style: StrokeStyle(lineWidth: 10 + pulse * 6, lineCap: .round))
                    .blur(radius: 8)
                    .opacity(brightness)
                // Bright core line on the very edge.
                frame.stroke(gradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .opacity(min(1, brightness + 0.2))
                    .blendMode(.plusLighter)
            }
            .drawingGroup()
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.8), value: player.accent)
        .onAppear { if disco.isOn { spread() } }
        .onChange(of: disco.isOn) { _, on in
            if on { spread() } else { withAnimation(.easeIn(duration: Self.retractDuration)) { progress = 0 } }
        }
    }

    private func spread() {
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: Self.spreadDuration)) { progress = 1 }
    }

}

extension TempoService {
    /// 0…1: live kick from the audio analyzer, or a decaying beat from the known tempo.
    func beatPulse(at date: Date, playing: Bool) -> Double {
        guard playing else { return 0 }
        if audio.isLive { return Double(audio.glowLevels().kick) }
        guard let beats = beats(at: date) else { return 0 }
        return exp(-4 * (beats - beats.rounded(.down)))
    }
}

// MARK: - Party (disco + idle Mac)

/// Stable pseudo-random 0…1 for tile shimmer and light spots.
private func hash01(_ a: Int, _ b: Int, _ c: Int = 0) -> Double {
    var h = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ c &* 83_492_791))
    h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33; h &*= 0xc4ceb9fe1a85ec53; h ^= h >> 33
    return Double(h % 10_000) / 10_000
}

/// Dimmed screen and a mirror ball lowered from the notch on a thread with reflections sweeping the walls.
/// Appears when the Mac is left alone, leaves on any input.
private struct PartyScene: View {
    let isPrimary: Bool
    @EnvironmentObject var disco: DiscoMode
    @EnvironmentObject var tempo: TempoService
    @EnvironmentObject var player: NowPlayingService

    /// Hand-rolled transition (Canvas can't interpolate state): value at the last change, where it heads, and when.
    @State private var from: Double = 0
    @State private var target: Double = 0
    @State private var changedAt = Date.distantPast

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: target == 0 && appear(at: .now) == 0)) { ctx in
            let now = ctx.date
            let a = appear(at: now)
            if a > 0 {
                content(appear: a, now: now)
            }
        }
        .onAppear { if disco.party { set(1) } }
        .onChange(of: disco.party) { _, on in set(on ? 1 : 0) }
    }

    private func set(_ value: Double) {
        from = appear(at: .now)
        target = value
        changedAt = .now
        // Settle once the leave finishes so the timeline pauses instead of ticking over an empty screen.
        if value == 0 {
            let stamp = changedAt
            DispatchQueue.main.asyncAfter(deadline: .now() + DiscoMode.partyLeaveDuration + 0.05) {
                if changedAt == stamp { from = 0 }
            }
        }
    }

    private func appear(at date: Date) -> Double {
        let entering = target > from
        let duration = entering ? DiscoMode.partyEnterDuration : DiscoMode.partyLeaveDuration
        let t = min(max(date.timeIntervalSince(changedAt) / duration, 0), 1)
        // Ease in-out both ways: the ladder routine is staged along this value and must not rush.
        let e = t * t * (3 - 2 * t)
        return from + (target - from) * e
    }

    @ViewBuilder
    private func content(appear a: Double, now: Date) -> some View {
        let beat = PartyBeat(date: now, tempo: tempo, playing: player.track?.isPlaying == true)
        let rotation = (beat.t * 0.45).truncatingRemainder(dividingBy: 2 * .pi)
        let accent = player.accent

        GeometryReader { geo in
            let size = geo.size
            let radius = min(size.width, size.height) * 0.075
            // The ball drops first, then the lights come up.
            let drop = min(a / 0.8, 1)
            let lights = max(0, (a - 0.35) / 0.65)
            let ballY = -radius * 1.2 + (size.height * 0.26 + radius * 1.2) * drop
                + sin(beat.t * 0.9) * 3 * drop   // gentle sway on the thread
            let ball = CGPoint(x: size.width / 2, y: ballY)

            ZStack {
                Color.black.opacity(0.84 * a)

                if isPrimary {
                    Reflections(center: ball, rotation: rotation, accent: accent,
                                pulse: beat.pulse, beatIndex: beat.index)
                        .opacity(lights)
                        .blendMode(.plusLighter)

                    // Cone of light hitting the ball from above.
                    RadialGradient(colors: [accent.opacity(0.25 + beat.pulse * 0.15), .clear],
                                   center: UnitPoint(x: 0.5, y: ballY / max(size.height, 1)),
                                   startRadius: radius, endRadius: radius * 6)
                        .opacity(lights)
                        .blendMode(.plusLighter)

                    Path { p in
                        p.move(to: CGPoint(x: size.width / 2, y: 0))
                        p.addLine(to: CGPoint(x: size.width / 2, y: ballY - radius))
                    }
                    .stroke(LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.5)], startPoint: .top, endPoint: .bottom),
                            lineWidth: 1.5)

                    MirrorBall(radius: radius, rotation: rotation, accent: accent, pulse: beat.pulse, beatIndex: beat.index)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(ball)


                    if let track = player.track {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(track.title).font(Theme.font(26, .bold)).foregroundStyle(.white)
                            Text(track.artist).font(Theme.font(17, .medium)).foregroundStyle(accent)
                        }
                        .lineLimit(1)
                        .frame(maxWidth: size.width * 0.35, alignment: .leading)
                        .shadow(color: .black.opacity(0.8), radius: 6)
                        .shadow(color: accent.opacity(0.5), radius: 12)
                        .opacity(lights)
                        .position(x: 60 + size.width * 0.175, y: size.height - 80)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// One frame of music: beat grid position and kick. Falls back to a 120 BPM grid without a known tempo.
private struct PartyBeat {
    let t: Double
    let beats: Double
    let pulse: Double

    var index: Int { Int(beats.rounded(.down)) }

    @MainActor
    init(date: Date, tempo: TempoService, playing: Bool) {
        t = date.timeIntervalSinceReferenceDate
        beats = tempo.beats(at: date) ?? t * 2
        pulse = tempo.beatPulse(at: date, playing: playing)
    }
}

/// Mirror ball: rows of tiles on a sphere, lit from the upper left, random tiles flash on the beat.
private struct MirrorBall: View {
    let radius: CGFloat
    let rotation: Double
    let accent: Color
    let pulse: Double
    let beatIndex: Int

    var body: some View {
        Canvas { ctx, size in
            let r = radius
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let sphere = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ctx.fill(sphere, with: .radialGradient(Gradient(colors: [Color(white: 0.35), Color(white: 0.06)]),
                                                   center: CGPoint(x: c.x - r * 0.35, y: c.y - r * 0.4),
                                                   startRadius: 0, endRadius: r * 1.4))
            ctx.clip(to: sphere)

            let light = (x: -0.45, y: -0.55, z: 0.70)
            let rows = 16
            for i in 0..<rows {
                let lat = -Double.pi / 2 + (Double(i) + 0.5) * .pi / Double(rows)
                let rowR = cos(lat) * r
                let n = max(6, Int(Double(rows) * 2 * cos(lat)))
                let y = c.y + sin(lat) * r
                let tileH = .pi * r / Double(rows) * cos(lat) * 0.86
                for j in 0..<n {
                    let lon = Double(j) * 2 * .pi / Double(n) + rotation
                    let facing = cos(lon)
                    guard facing > 0.02 else { continue }
                    let x = c.x + sin(lon) * rowR
                    let tileW = 2 * .pi * rowR / Double(n) * facing * 0.86
                    let normal = (x: sin(lon) * cos(lat), y: sin(lat), z: facing * cos(lat))
                    let lit = max(0, normal.x * light.x + normal.y * light.y + normal.z * light.z)
                    let spec = pow(lit, 10)
                    let flash = hash01(i, j, beatIndex) > 1 - pulse * 0.12 ? 1.0 : 0
                    let rect = CGRect(x: x - tileW / 2, y: y - tileH / 2, width: tileW, height: tileH)
                    ctx.fill(Path(rect), with: .color(accent.opacity(0.12 + 0.45 * lit * (0.5 + hash01(i, j)))))
                    ctx.fill(Path(rect), with: .color(.white.opacity(min(1, spec * 0.9 + flash))))
                }
            }
        }
        .shadow(color: accent.opacity(0.5 + pulse * 0.3), radius: 18 + pulse * 10)
    }
}

/// Light spots thrown by the ball, sweeping around the room as it turns.
private struct Reflections: View {
    let center: CGPoint
    let rotation: Double
    let accent: Color
    let pulse: Double
    let beatIndex: Int

    var body: some View {
        Canvas { ctx, size in
            ctx.addFilter(.blur(radius: 2.5))
            for k in 0..<70 {
                let lon = hash01(k, 1) * 2 * .pi + rotation
                let depth = cos(lon)
                guard depth > 0.05 else { continue }
                let x = size.width / 2 + sin(lon) * size.width * 0.62
                let y = center.y + (hash01(k, 2) * 1.5 - 0.45) * size.height * 0.75
                let base = 5 + hash01(k, 3) * 9
                let s = base * (1 + pulse * 0.5)
                let w = s * (0.4 + 0.6 * depth)
                let alpha = depth * (0.35 + 0.65 * pulse) * (hash01(k, beatIndex) > 0.85 ? 1 : 0.6)
                let rect = CGRect(x: x - w, y: y - s, width: w * 2, height: s * 2)
                let tint: Color = hash01(k, 4) > 0.55 ? .white : accent
                ctx.fill(Path(ellipseIn: rect), with: .color(tint.opacity(alpha)))
            }
        }
    }
}
