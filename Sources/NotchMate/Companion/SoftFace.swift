import SwiftUI

/// The resting expression of a mood. Numbers are springs; the eye shape switches with a pop.
/// Movement and props live in `FaceScene`.
struct FacePose: Equatable {
    enum EyeShape: Equatable { case capsule, heart, star }

    var eyeHeight = 1.0, eyeWidth = 1.0
    /// Bottom lid that turns the eyes into happy arcs.
    var smile = 0.0
    /// Top lid: how low (0…1) and its slant (−1 sad … +1 determined).
    var lid = 0.0, lidSlant = 0.0
    /// Eyes shut into ‿ lines.
    var closed = 0.0
    var winkRight = 0.0
    var shape = EyeShape.capsule
    /// −1 frown … +1 smile; `mouthOpen` shows a mouth with a tongue, `oh` a round mouth.
    var mouth = 0.3, mouthOpen = 0.0, oh = 0.0, mouthWidth = 1.0
    /// Blush, only for affectionate and shy moods.
    var cheeks = 0.0
    /// Where the eyes rest, in face units.
    var gaze = CGPoint.zero
    var droop = 0.0

    static func pose(for mood: Mood) -> FacePose {
        var p = FacePose()
        switch mood {
        case .idle, .nod: break
        case .startup: p.closed = 1; p.mouth = 0.1
        case .happy: p.eyeHeight = 0.8; p.eyeWidth = 1.12; p.smile = 1; p.mouthOpen = 1; p.cheeks = 0.45
        case .love: p.shape = .heart; p.mouth = 0.8; p.mouthOpen = 0.6; p.cheeks = 0.7
        case .sleepy: p.closed = 1; p.mouth = 0; p.oh = 0.35; p.droop = 1
        case .focused: p.lid = 0.32; p.lidSlant = 0.35; p.eyeWidth = 1.05; p.mouth = 0; p.mouthWidth = 0.7; p.gaze = CGPoint(x: 0, y: 1.5)
        case .excited: p.shape = .star; p.mouthOpen = 1; p.cheeks = 0.4
        case .surprised: p.eyeHeight = 1.3; p.eyeWidth = 1.08; p.oh = 1; p.mouth = 0
        case .tired: p.lid = 0.55; p.lidSlant = -0.3; p.mouth = 0; p.mouthWidth = 0.7; p.droop = 2
        case .music: p.eyeHeight = 0.8; p.smile = 1; p.mouth = 0.7
        case .eating: p.eyeHeight = 0.8; p.smile = 0.9; p.mouthOpen = 0.5
        case .wink: p.winkRight = 1; p.mouth = 0.8; p.cheeks = 0.5
        case .alert: p.eyeHeight = 1.25; p.oh = 0.6; p.mouth = 0
        case .message: p.eyeHeight = 1.1; p.oh = 0.4; p.gaze = CGPoint(x: 3, y: -1)
        case .shutter: p.mouth = 0.6
        case .call: p.eyeHeight = 0.9; p.mouth = 0.3; p.mouthWidth = 0.8; p.gaze = CGPoint(x: 2, y: 0)
        case .sad: p.eyeHeight = 0.9; p.eyeWidth = 0.95; p.lid = 0.35; p.lidSlant = -1; p.mouth = -0.8; p.droop = 1
        case .proud: p.eyeHeight = 0.8; p.smile = 1; p.mouthOpen = 1; p.gaze = CGPoint(x: 0, y: -1.5)
        case .agent: p.eyeHeight = 0.9; p.mouth = 0.2; p.mouthWidth = 0.7
        case .ready: p.eyeHeight = 0.8; p.smile = 1; p.mouthOpen = 1
        case .disappointed: p.lid = 0.5; p.mouth = -0.1; p.mouthWidth = 0.75; p.gaze = CGPoint(x: -3, y: 0.5)
        case .relax: p.eyeHeight = 0.8; p.smile = 0.9; p.mouth = 0.6
        case .flow: p.lid = 0.3; p.lidSlant = 0.4; p.mouth = 0.1; p.mouthWidth = 0.6
        case .bored: p.lid = 0.5; p.mouth = -0.1; p.mouthWidth = 0.6; p.droop = 1
        case .fishing: p.mouth = 0.4; p.gaze = CGPoint(x: 3, y: 1.5)
        case .basketball: p.mouth = 0.5; p.mouthOpen = 0.4
        case .watch: p.eyeHeight = 1.08; p.mouth = 0.4
        case .breathe: p.closed = 1; p.mouth = 0.4
        case .stressed: p.eyeHeight = 1.1; p.lid = 0.2; p.lidSlant = -0.5; p.mouth = -0.4
        case .zen: p.closed = 1; p.mouth = 0.5
        case .charged: p.shape = .star; p.mouthOpen = 1
        case .drained: p.lid = 0.6; p.eyeHeight = 0.75; p.oh = 0.3; p.droop = 2.5
        }
        return p
    }
}

/// A prop or particle of a scene, in face units (the face is 96 × 60).
struct FaceSprite {
    enum Kind {
        case symbol(String)
        case text(String)
        case circle
        case ring(width: CGFloat)
        case line(to: CGPoint, width: CGFloat)
        case drop
        case bars([Double])
    }
    var kind: Kind
    var at: CGPoint
    var size: CGFloat = 18
    var angle = 0.0
    var opacity = 1.0
    var color: Color? = nil
    /// Moves with the face (a tear) instead of staying put (a ball).
    var attached = false
}

/// What a mood does over time: body movement, quick overrides of the face and its props.
struct FaceLive {
    var dx = 0.0, dy = 0.0, tilt = 0.0, sx = 1.0, sy = 1.0
    var gaze = CGPoint.zero
    /// Extra closing of the eyes (0 open … 1 shut) and an eye size pulse.
    var close = 0.0, eyeScale = 1.0, eyeSpin = 0.0
    var mouthOpen: Double? = nil, oh: Double? = nil, happyEyes: Double? = nil
    var winkRight: Double? = nil
    var sprites: [FaceSprite] = []
    /// Moods that keep moving redraw at full rate.
    var animated = true
}

/// Short looping performances, one per mood.
enum FaceScene {
    static let pink = Color(red: 1, green: 0.42, blue: 0.6)
    static let water = Color(red: 0.45, green: 0.78, blue: 1)
    static let gold = Color(red: 1, green: 0.82, blue: 0.3)

    // MARK: Motion helpers

    static func clamp(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1, y = clamp(x) - 1
        return 1 + c3 * y * y * y + c1 * y * y
    }
    static func easeInOut(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
    /// 0→1 with overshoot, starting at `delay`.
    static func pop(_ t: Double, delay: Double = 0, duration: Double = 0.4) -> Double { easeOutBack((t - delay) / duration) }
    static func phase(_ t: Double, _ period: Double, offset: Double = 0) -> Double {
        let p = (t / period + offset).truncatingRemainder(dividingBy: 1)
        return p < 0 ? p + 1 : p
    }
    /// A hop with stretch in the air and squash on landing.
    static func hop(_ live: inout FaceLive, t: Double, period: Double, height: Double) {
        let p = phase(t, period)
        if p < 0.65 {
            let k = p / 0.65
            live.dy -= sin(k * .pi) * height
            live.sy *= 1 + 0.07 * sin(k * .pi)
            live.sx *= 1 - 0.04 * sin(k * .pi)
        } else {
            let k = (p - 0.65) / 0.35
            live.sy *= 1 - 0.14 * sin(k * .pi)
            live.sx *= 1 + 0.09 * sin(k * .pi)
        }
    }
    /// Particles that rise and fade, spread over `count` staggered lifetimes.
    static func rising(_ t: Double, count: Int, period: Double, from: CGPoint, travel: CGPoint, wobble: Double = 4,
                       make: (Int, Double, CGPoint) -> FaceSprite) -> [FaceSprite] {
        (0..<count).map { i in
            let p = phase(t, period, offset: Double(i) / Double(count))
            let at = CGPoint(x: from.x + travel.x * p + sin(p * 6 + Double(i)) * wobble, y: from.y + travel.y * p)
            var s = make(i, p, at)
            s.opacity *= sin(p * .pi)
            return s
        }
    }

    // MARK: Scenes

    static func live(for mood: Mood, t: Double) -> FaceLive {
        var l = FaceLive()
        switch mood {
        case .idle:
            l.sy = 1 + sin(t * 1.7) * 0.012
            l.tilt = sin(t * 0.5) * 0.025
            l.animated = false

        case .startup:
            // Wakes up: shut, a flutter, a big stretch, a look around.
            // Negative `close` opens the shut resting eyes.
            if t > 0.9 { l.close = t < 1.5 ? -(0.5 - 0.5 * cos((t - 0.9) * 21)) : -1 }
            let stretch = t > 1.5 && t < 2.4 ? sin((t - 1.5) / 0.9 * .pi) : 0
            l.sy = 1 + 0.12 * stretch; l.sx = 1 - 0.06 * stretch
            if t > 2.4 { l.gaze = CGPoint(x: sin((t - 2.4) * 2.2) * 3.5, y: 0) }
            let sun = pop(t, delay: 1.5)
            l.sprites.append(FaceSprite(kind: .symbol("sun.max.fill"), at: CGPoint(x: 86, y: 12 - sun * 2), size: 18 * sun, angle: t * 0.6, color: gold))

        case .happy:
            hop(&l, t: t, period: 0.85, height: 4)
            l.tilt = sin(t * 3.7) * 0.07
            for (i, x) in [10.0, 86.0].enumerated() {
                let k = 0.6 + 0.4 * sin(t * 5 + Double(i) * .pi)
                l.sprites.append(FaceSprite(kind: .symbol("sparkle"), at: CGPoint(x: x, y: 14 + Double(i) * 4), size: 14 * k, angle: t, color: gold))
            }

        case .love:
            // Lub-dub heartbeat in the eyes, hearts floating up on both sides.
            let beat = phase(t, 1.1)
            l.eyeScale = 1 + 0.16 * max(sin(min(beat / 0.15, 1) * .pi), 0) + 0.1 * max(sin(clamp((beat - 0.22) / 0.15) * .pi), 0)
            l.tilt = sin(t * 1.6) * 0.06
            l.sprites += rising(t, count: 4, period: 2.6, from: CGPoint(x: 0, y: 54), travel: CGPoint(x: 0, y: -52)) { i, p, at in
                FaceSprite(kind: .symbol("heart.fill"), at: CGPoint(x: i % 2 == 0 ? 10 + at.x : 86 + at.x, y: at.y), size: 10 + 8 * p, angle: sin(p * 8) * 0.25, color: pink)
            }

        case .sleepy:
            // Nods off, jerks awake, drifts off again.
            let c = phase(t, 4.5)
            l.dy += c < 0.75 ? easeInOut(c / 0.75) * 4 : 4 * (1 - easeOutBack((c - 0.75) / 0.12))
            l.tilt = c < 0.75 ? easeInOut(c / 0.75) * 0.08 : 0
            if c > 0.76 && c < 0.88 { l.close = -0.55 }
            l.oh = 0.3 + 0.12 * sin(t * 1.5)
            l.sprites += rising(t, count: 3, period: 2.4, from: CGPoint(x: 72, y: 26), travel: CGPoint(x: 18, y: -26), wobble: 2) { _, p, at in
                FaceSprite(kind: .text("z"), at: at, size: 8 + 12 * p, angle: -0.2)
            }

        case .focused:
            l.sx = 1.03; l.sy = 1.03
            l.gaze = CGPoint(x: sin(t * 0.9) * 1.5, y: 0)
            // An hourglass that flips every few seconds.
            let flip = phase(t, 3.2)
            let angle = flip > 0.85 ? easeInOut((flip - 0.85) / 0.15) * .pi : 0
            l.sprites.append(FaceSprite(kind: .symbol("hourglass"), at: CGPoint(x: 86, y: 16), size: 20, angle: angle))

        case .excited:
            hop(&l, t: t, period: 0.5, height: 6)
            l.eyeSpin = t * 3
            l.sprites += (0..<5).map { i in
                let p = phase(t, 0.9, offset: Double(i) / 5)
                let a = Double(i) / 5 * 2 * .pi + t * 0.5
                return FaceSprite(kind: .symbol("sparkle"), at: CGPoint(x: 48 + cos(a) * (36 + 12 * p), y: 30 + sin(a) * (22 + 8 * p)),
                                  size: 8 + 8 * sin(p * .pi), opacity: sin(p * .pi), color: i % 2 == 0 ? gold : nil)
            }

        case .surprised:
            // Anticipation squash, a jump, then a little tremble.
            if t < 0.15 { l.sy = 1 - 0.15 * (t / 0.15); l.sx = 1 + 0.1 * (t / 0.15) }
            else if t < 0.55 { let k = (t - 0.15) / 0.4; l.dy -= sin(k * .pi) * 6; l.sy = 1 + 0.08 * sin(k * .pi) }
            else { l.dx = sin(t * 40) * 0.4 }
            l.eyeScale = 1 + 0.15 * pop(t, delay: 0.15, duration: 0.3) - 0.15 * clamp((t - 0.6) / 0.6)
            let k = pop(t, delay: 0.2)
            l.sprites.append(FaceSprite(kind: .text("!?"), at: CGPoint(x: 86, y: 14 - 3 * k), size: 18 * k, angle: sin(t * 6) * 0.12, color: gold))

        case .tired:
            // Slow yawns and a battery that blinks red.
            let y = phase(t, 5)
            if y < 0.3 {
                let k = sin(y / 0.3 * .pi)
                l.oh = 1.4 * k; l.close = 0.9 * k; l.dy -= 2 * k; l.tilt = -0.06 * k
            }
            l.dy += sin(t * 0.8) * 0.6
            l.sprites.append(FaceSprite(kind: .symbol("battery.25percent"), at: CGPoint(x: 85, y: 12), size: 22, opacity: phase(t, 1) < 0.5 ? 1 : 0.35, color: .red))

        case .music:
            l.tilt = sin(t * 2.6) * 0.12
            l.dx = sin(t * 2.6) * 3
            l.dy -= abs(sin(t * 5.2)) * 1.5
            l.sprites += rising(t, count: 4, period: 2.2, from: CGPoint(x: 0, y: 46), travel: CGPoint(x: 0, y: -44), wobble: 3) { i, p, at in
                FaceSprite(kind: .symbol(i % 2 == 0 ? "music.note" : "music.quarternote.3"), at: CGPoint(x: i % 2 == 0 ? 10 + at.x : 86 + at.x, y: at.y),
                           size: 12 + 6 * p, angle: sin(p * 6) * 0.3)
            }

        case .eating:
            // Chews, takes bites of a carrot, crumbs fall.
            let chew = abs(sin(t * 7))
            l.mouthOpen = 0.25 + 0.6 * chew
            l.sy = 1 + 0.03 * chew
            let bite = phase(t, 1.6)
            let reach = bite < 0.25 ? sin(bite / 0.25 * .pi) : 0
            l.sprites.append(FaceSprite(kind: .symbol("carrot.fill"), at: CGPoint(x: 80 - 14 * reach, y: 42 - 2 * reach), size: 20, angle: -0.6 + reach * 0.3, color: .orange))
            l.sprites += (0..<3).map { i in
                let p = phase(t, 0.9, offset: Double(i) / 3)
                return FaceSprite(kind: .circle, at: CGPoint(x: 46 + Double(i) * 3 + p * 4, y: 48 + p * 12), size: 2, opacity: 1 - p, color: .orange)
            }

        case .wink:
            l.winkRight = t > 0.15 && t < 1.6 ? 1 : 0
            l.tilt = 0.08 * pop(t, duration: 0.5)
            let p = phase(t, 2)
            l.sprites.append(FaceSprite(kind: .symbol("sparkle"), at: CGPoint(x: 70 + 20 * p, y: 24 - 20 * p), size: 8 + 10 * sin(p * .pi), angle: p * 4,
                                        opacity: sin(p * .pi), color: gold))

        case .alert:
            // A big "!" drops in and shakes; the face looks around.
            let drop = clamp(t / 0.5)
            let bounce = drop < 1 ? -30 * pow(1 - drop, 2) : 0
            let shake = t > 0.5 ? sin(t * 22) * 0.18 * max(0, 1 - phase(t, 1.4) * 2) : 0
            l.gaze = CGPoint(x: phase(t, 1.4) < 0.5 ? -3 : 3, y: 0)
            l.sprites.append(FaceSprite(kind: .symbol("exclamationmark.circle.fill"), at: CGPoint(x: 86, y: 16 + bounce), size: 22, angle: shake, color: .orange))

        case .message:
            // An envelope flies in, then wiggles for attention.
            let fly = pop(t, duration: 0.55)
            let wiggle = t > 0.55 ? sin(t * 9) * 0.18 : 0
            l.sprites.append(FaceSprite(kind: .symbol("envelope.fill"), at: CGPoint(x: 120 - 36 * fly, y: 16 - abs(sin(t * 4.5)) * 2), size: 22, angle: wiggle))
            hop(&l, t: t, period: 1.4, height: 1.5)

        case .shutter:
            // Camera flash: squint against the burst of light.
            let f = phase(t, 2.2)
            let flash = f < 0.25 ? f / 0.25 : 1.0
            l.close = f < 0.3 ? 0.8 * sin(f / 0.3 * .pi) : 0
            l.winkRight = f > 0.3 && f < 0.7 ? 1 : 0
            l.sprites.append(FaceSprite(kind: .ring(width: 3), at: CGPoint(x: 84, y: 16), size: 10 + 50 * flash, opacity: 1 - flash, color: .white))
            l.sprites.append(FaceSprite(kind: .symbol("camera.fill"), at: CGPoint(x: 84, y: 16), size: 20 * (f < 0.1 ? 0.9 : 1)))

        case .call:
            // Listening along to live sound bars, nodding now and then.
            let bars = (0..<4).map { i in 0.35 + 0.65 * abs(sin(t * (5 + Double(i) * 1.7) + Double(i))) }
            l.sprites.append(FaceSprite(kind: .bars(bars), at: CGPoint(x: 86, y: 30), size: 20))
            let n = phase(t, 3.5)
            if n < 0.2 { l.dy += sin(n / 0.2 * .pi * 2) * 1.5 }

        case .sad:
            // A tear wells up, rolls down and falls; the lip trembles.
            let c = phase(t, 2.6)
            let grow = clamp(c / 0.4), fall = clamp((c - 0.4) / 0.6)
            l.sprites.append(FaceSprite(kind: .drop, at: CGPoint(x: 27, y: 36 + 24 * fall * fall), size: 3 + 5 * grow, opacity: 1 - fall * 0.8, color: water, attached: true))
            l.mouthOpen = nil
            l.dx = sin(t * 18) * 0.25
            l.tilt = sin(t * 0.7) * 0.04

        case .proud:
            l.dy -= 2 + sin(t * 1.4) * 0.8
            let n = phase(t, 2.4)
            if n < 0.25 { l.dy += sin(n / 0.25 * .pi) * 2 }
            let tw = 0.85 + 0.15 * sin(t * 6)
            l.sprites.append(FaceSprite(kind: .symbol("star.fill"), at: CGPoint(x: 86, y: 13), size: 20 * tw, angle: t * 0.8, color: gold))
            l.sprites += rising(t, count: 2, period: 1.6, from: CGPoint(x: 78, y: 24), travel: CGPoint(x: -6, y: -20), wobble: 2) { _, p, at in
                FaceSprite(kind: .symbol("sparkle"), at: at, size: 6 + 6 * p, color: gold)
            }

        case .nod:
            l.dy += sin(t * 7.5) * 3
            l.gaze = CGPoint(x: 0, y: max(sin(t * 7.5), 0) * 1.5)
            l.close = max(sin(t * 7.5), 0) * 0.3

        case .agent:
            // Reads the laptop line by line while code flies out of it.
            let r = phase(t, 1.3)
            l.gaze = CGPoint(x: r < 0.85 ? -3 + 6 * (r / 0.85) : 3 - 6 * ((r - 0.85) / 0.15), y: 2.5)
            l.sprites.append(FaceSprite(kind: .symbol("laptopcomputer"), at: CGPoint(x: 84, y: 46), size: 24))
            l.sprites += rising(t, count: 3, period: 1.5, from: CGPoint(x: 84, y: 40), travel: CGPoint(x: 0, y: -30), wobble: 4) { i, p, at in
                FaceSprite(kind: .text(["{", "}", "<>"][i]), at: at, size: 8 + 4 * p, color: Color(red: 0.55, green: 0.9, blue: 0.7))
            }

        case .ready:
            hop(&l, t: t, period: 1.5, height: 3)
            let r = phase(t, 1.5)
            let swing = sin(t * 16) * 0.5 * (1 - r)
            l.sprites.append(FaceSprite(kind: .symbol("bell.fill"), at: CGPoint(x: 86, y: 15), size: 21, angle: swing, color: gold))
            l.sprites.append(FaceSprite(kind: .ring(width: 1.5), at: CGPoint(x: 86, y: 15), size: 22 + 20 * r, opacity: (1 - r) * 0.8, color: gold))

        case .disappointed:
            // A long sigh with a puff of air.
            let s = phase(t, 3.6)
            let sigh = s < 0.5 ? sin(s / 0.5 * .pi) : 0
            l.dy += 3 * sigh; l.sy = 1 - 0.04 * sigh
            l.oh = s > 0.15 && s < 0.4 ? 0.5 : nil
            if s > 0.2 && s < 0.7 {
                let k = (s - 0.2) / 0.5
                l.sprites.append(FaceSprite(kind: .symbol("wind"), at: CGPoint(x: 38 - 26 * k, y: 46), size: 12 + 4 * k, opacity: 1 - k))
            }

        case .relax:
            // Coffee with rising steam and a slow sip.
            let s = phase(t, 4.5)
            let sip = s > 0.7 && s < 0.95 ? sin((s - 0.7) / 0.25 * .pi) : 0
            l.tilt = 0.1 * sip; l.dx = 3 * sip; l.close = 0.6 * sip
            l.dy += sin(t * 1.2) * 0.8
            l.sprites.append(FaceSprite(kind: .symbol("cup.and.saucer.fill"), at: CGPoint(x: 84, y: 46), size: 22, color: Color(red: 0.85, green: 0.68, blue: 0.5)))
            l.sprites += rising(t, count: 3, period: 1.8, from: CGPoint(x: 84, y: 36), travel: CGPoint(x: 0, y: -26), wobble: 3) { _, p, at in
                FaceSprite(kind: .circle, at: at, size: 3 + 4 * p, opacity: 0.55)
            }

        case .flow:
            // Wind streaks rush past a determined face.
            l.sx = 1.02; l.tilt = -0.03
            l.sprites += (0..<5).map { i in
                let p = phase(t, 0.7, offset: Double(i) / 5)
                let y = 8 + Double(i) * 11
                let x = 100 - 110 * p
                return FaceSprite(kind: .line(to: CGPoint(x: x + 10, y: y), width: 1.6), at: CGPoint(x: x, y: y), opacity: 0.25 + 0.5 * sin(p * .pi))
            }

        case .bored:
            // Eyes roll around, an occasional yawn.
            let a = t * 1.4
            l.gaze = CGPoint(x: cos(a) * 3, y: sin(a) * 1.5 - 0.5)
            let y = phase(t, 6)
            if y < 0.2 { let k = sin(y / 0.2 * .pi); l.oh = 1.1 * k; l.close = 0.7 * k }
            l.tilt = -0.05
            l.sprites.append(FaceSprite(kind: .text("…"), at: CGPoint(x: 86, y: 14), size: 16, opacity: 0.4 + 0.4 * sin(t * 2)))

        case .fishing:
            // A rod over the side, the float bobbing; now and then a bite.
            let c = phase(t, 5)
            let bite = c > 0.8 ? sin((c - 0.8) / 0.2 * .pi) : 0
            let float = CGPoint(x: 86, y: 46 + sin(t * 2.4) * 1.2 + bite * 5)
            l.sprites.append(FaceSprite(kind: .line(to: float, width: 1), at: CGPoint(x: 94, y: 0), opacity: 0.8))
            l.sprites.append(FaceSprite(kind: .circle, at: float, size: 6, color: .red))
            l.eyeScale = 1 + 0.15 * bite
            if bite > 0.1 {
                l.sprites.append(FaceSprite(kind: .symbol("fish.fill"), at: CGPoint(x: 76 + 10 * (c - 0.8) / 0.2, y: 50 - 14 * bite), size: 16, angle: -0.5 + bite, color: water))
            }

        case .basketball:
            // Dribbles a ball; the eyes follow it.
            let b = abs(sin(t * 3.2))
            let y = 54 - b * 40
            let squash = b < 0.12 ? 1 - (0.12 - b) * 2 : 1
            l.sprites.append(FaceSprite(kind: .symbol("basketball.fill"), at: CGPoint(x: 85, y: y), size: 18 * squash, angle: t * 3, color: .orange))
            l.gaze = CGPoint(x: 3, y: (y - 30) / 10)
            l.dy += (1 - b) * 1.2

        case .watch:
            // Following the cursor: the eyes and head track it in the renderer, nothing else moves.
            l.sy = 1 + sin(t * 1.7) * 0.012
            l.animated = false

        case .breathe:
            l.animated = true

        case .stressed:
            // Shakes, sweat rolls down, eyes dart around.
            l.dx = sin(t * 47) * 0.6
            let d = phase(t, 0.9)
            l.gaze = CGPoint(x: d < 0.5 ? -2.5 : 2.5, y: -0.5)
            let s = phase(t, 1.8)
            l.sprites.append(FaceSprite(kind: .drop, at: CGPoint(x: 14, y: 8 + 22 * s * s), size: 7, opacity: 1 - s * 0.7, color: water, attached: true))

        case .zen:
            // Floats with sparkles slowly orbiting.
            l.dy += sin(t * 1.1) * 3
            l.sprites += (0..<3).map { i in
                let a = t * 0.7 + Double(i) * 2 * .pi / 3
                return FaceSprite(kind: .symbol("sparkle"), at: CGPoint(x: 48 + cos(a) * 42, y: 30 + sin(a) * 22),
                                  size: 9 + 4 * sin(t * 2 + Double(i)), opacity: 0.5 + 0.5 * sin(a), color: i == 0 ? gold : nil)
            }

        case .charged:
            hop(&l, t: t, period: 0.7, height: 4)
            l.eyeSpin = t * 2
            let flash = phase(t, 0.7) < 0.2
            l.sprites.append(FaceSprite(kind: .symbol("bolt.fill"), at: CGPoint(x: 10, y: 16), size: 20, angle: -0.2, opacity: flash ? 1 : 0.7, color: gold))
            l.sprites.append(FaceSprite(kind: .symbol("battery.100percent.bolt"), at: CGPoint(x: 85, y: 14), size: 22, color: .green))

        case .drained:
            // Deflates, sways weakly, the empty battery blinks.
            l.dy += 1 + sin(t * 0.9) * 1
            l.tilt = sin(t * 0.7) * 0.06
            l.sy = 1 - 0.03 * (0.5 + 0.5 * sin(t * 0.9))
            l.sprites.append(FaceSprite(kind: .symbol("battery.0percent"), at: CGPoint(x: 85, y: 14), size: 22, opacity: phase(t, 1.2) < 0.5 ? 1 : 0.3, color: .red))
        }
        makeRoom(&l)
        return l
    }

    /// The face steps aside from a big prop so it never covers an eye.
    static func makeRoom(_ l: inout FaceLive) {
        let props = l.sprites.filter { !$0.attached && $0.size >= 14 && $0.opacity > 0.3 }
        let right = props.contains { $0.at.x > 72 }, left = props.contains { $0.at.x < 24 }
        if right != left { l.dx += right ? -5 : 5 }
    }
}

/// Spring state of the soft face between frames: blinks, glances and the way it settles into a new mood.
@MainActor
final class FaceMotion {
    private enum Key: Int, CaseIterable { case eyeHeight, eyeWidth, smile, lid, lidSlant, closed, wink, mouth, open, oh, width, cheeks, gazeX, gazeY, droop, pop }
    private var value = [Double](repeating: 0, count: Key.allCases.count)
    private var velocity = [Double](repeating: 0, count: Key.allCases.count)
    private var started = false
    private var last: Date?
    private(set) var shape = FacePose.EyeShape.capsule
    private var mood: Mood?
    private var moodStart = Date()
    private var animated = false

    private var nextBlink = Date()
    private var blinkStart: Date?
    private var nextGlance = Date()
    private var glance = CGPoint.zero, glanceTarget = CGPoint.zero

    /// Settled faces redraw slowly; moving ones get smooth frames.
    func isBusy(at date: Date) -> Bool {
        if animated { return true }
        if let blinkStart, date.timeIntervalSince(blinkStart) < 0.25 { return true }
        if nextBlink.timeIntervalSince(date) < 0.15 || nextGlance.timeIntervalSince(date) < 0.15 { return true }
        if abs(glanceTarget.x - glance.x) + abs(glanceTarget.y - glance.y) > 0.05 { return true }
        return velocity.contains { abs($0) > 0.002 }
    }

    struct Frame {
        var pose: FacePose
        var live: FaceLive
        var blink: Double      // 1 open … 0 shut
        var squash: Double     // eyes widen while blinking
        var glance: CGPoint
        var pop: Double
    }

    func advance(to date: Date, mood: Mood, lively: Bool) -> Frame {
        let target = FacePose.pose(for: mood)
        let goal = values(of: target)
        if self.mood != mood {
            self.mood = mood
            moodStart = date
        }
        if !started {
            value = goal
            value[Key.pop.rawValue] = 1
            shape = target.shape
            started = true
            scheduleBlink(after: date)
        }
        if target.shape != shape {
            shape = target.shape
            value[Key.pop.rawValue] = 0.4
        }
        // Fixed 60 Hz steps keep the spring identical at any frame rate.
        var dt = min(max(date.timeIntervalSince(last ?? date), 0), 0.25)
        last = date
        while dt > 0 {
            let step = min(dt, 1 / 60)
            for i in value.indices {
                velocity[i] = (velocity[i] + (goal[i] - value[i]) * 0.09) * 0.8
                value[i] += velocity[i] * step * 60
            }
            glance.x += (glanceTarget.x - glance.x) * 0.35 * step * 60
            glance.y += (glanceTarget.y - glance.y) * 0.35 * step * 60
            dt -= step
        }
        let live = FaceScene.live(for: mood, t: date.timeIntervalSince(moodStart))
        animated = lively && live.animated
        // Scenes with their own gaze don't get random glances on top.
        if lively, live.gaze == .zero, date >= nextGlance {
            glanceTarget = CGPoint(x: .random(in: -3...3), y: .random(in: -1.2...1.2))
            nextGlance = date.addingTimeInterval(.random(in: 0.9...2.8))
        }
        if !lively || live.gaze != .zero { glanceTarget = .zero }

        var blink = 1.0
        if blinkStart == nil, date >= nextBlink { blinkStart = date }
        if let start = blinkStart {
            let k = date.timeIntervalSince(start) / 0.18
            if k >= 1 {
                blinkStart = nil
                scheduleBlink(after: date)
            } else {
                blink = max(0.05, abs(k - 0.5) * 2)
            }
        }

        var pose = target
        pose.eyeHeight = value[Key.eyeHeight.rawValue]; pose.eyeWidth = value[Key.eyeWidth.rawValue]
        pose.smile = live.happyEyes ?? value[Key.smile.rawValue]; pose.lid = value[Key.lid.rawValue]; pose.lidSlant = value[Key.lidSlant.rawValue]
        pose.closed = value[Key.closed.rawValue]; pose.winkRight = live.winkRight ?? value[Key.wink.rawValue]
        pose.mouth = value[Key.mouth.rawValue]; pose.mouthOpen = live.mouthOpen ?? value[Key.open.rawValue]; pose.oh = live.oh ?? value[Key.oh.rawValue]
        pose.mouthWidth = value[Key.width.rawValue]; pose.cheeks = value[Key.cheeks.rawValue]
        pose.gaze = CGPoint(x: value[Key.gazeX.rawValue] + live.gaze.x, y: value[Key.gazeY.rawValue] + live.gaze.y)
        pose.droop = value[Key.droop.rawValue]
        pose.shape = shape
        return Frame(pose: pose, live: live, blink: blink, squash: 1 + (1 - blink) * 0.18, glance: glance, pop: value[Key.pop.rawValue])
    }

    private func scheduleBlink(after date: Date) {
        // Now and then a quick double blink.
        nextBlink = date.addingTimeInterval(Double.random(in: 0...1) < 0.15 ? 0.25 : .random(in: 2.4...5.5))
    }

    private func values(of p: FacePose) -> [Double] {
        var v = [Double](repeating: 0, count: Key.allCases.count)
        v[Key.eyeHeight.rawValue] = p.eyeHeight; v[Key.eyeWidth.rawValue] = p.eyeWidth; v[Key.smile.rawValue] = p.smile
        v[Key.lid.rawValue] = p.lid; v[Key.lidSlant.rawValue] = p.lidSlant; v[Key.closed.rawValue] = p.closed
        v[Key.wink.rawValue] = p.winkRight; v[Key.mouth.rawValue] = p.mouth; v[Key.open.rawValue] = p.mouthOpen
        v[Key.oh.rawValue] = p.oh; v[Key.width.rawValue] = p.mouthWidth; v[Key.cheeks.rawValue] = p.cheeks
        v[Key.gazeX.rawValue] = p.gaze.x; v[Key.gazeY.rawValue] = p.gaze.y; v[Key.droop.rawValue] = p.droop
        v[Key.pop.rawValue] = 1
        return v
    }
}

/// Redraws fast while the face moves and slowly once it has settled.
struct FaceSchedule: TimelineSchedule {
    let motion: FaceMotion
    let fast: TimeInterval
    let slow: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        let lowFrequency = mode == .lowFrequency
        return AnyIterator {
            let current = next
            let busy = MainActor.assumeIsolated { motion.isBusy(at: current) }
            next = current.addingTimeInterval(lowFrequency ? max(slow, 1) : (busy ? fast : slow))
            return current
        }
    }
}

/// Draws one frame of the soft face in a 96 × 60 unit box.
enum SoftFaceRenderer {
    static let cheek = Color(red: 1, green: 0.48, blue: 0.62)

    static func draw(_ frame: FaceMotion.Frame, in context: inout GraphicsContext, size: CGSize, color: Color,
                     time t: TimeInterval, look: CGPoint, dance: (lift: Double, sway: Double, squash: Double)?, breath: Double?) {
        let p = frame.pose, live = frame.live
        let u = min(size.width / 96, size.height / 60)
        context.translateBy(x: (size.width - 96 * u) / 2, y: (size.height - 60 * u) / 2)
        context.scaleBy(x: u, y: u)
        let world = context

        // Body movement pivots on the chin, so squash and stretch look grounded.
        // The head leans a little after the eyes when they follow the cursor.
        var dy = p.droop + live.dy + look.y * 1.2, dx = live.dx + look.x * 2, tilt = live.tilt + look.x * 0.05
        var sx = live.sx, sy = live.sy
        if let breath { sx *= 0.92 + 0.14 * breath; sy *= 0.92 + 0.14 * breath }
        if let dance {
            dy -= dance.lift; tilt += dance.sway; dx += dance.sway * 20
            sy *= dance.squash; sx *= 2 - dance.squash
        }
        context.translateBy(x: 48 + dx, y: 50 + dy)
        context.rotate(by: .radians(tilt))
        context.scaleBy(x: sx, y: sy)
        context.translateBy(x: -48, y: -50)

        let eyeLook = CGPoint(x: p.gaze.x + frame.glance.x + look.x * 3, y: p.gaze.y + frame.glance.y + look.y * 2)
        for (i, centre) in [CGPoint(x: 33, y: 28), CGPoint(x: 63, y: 28)].enumerated() {
            drawEye(at: CGPoint(x: centre.x + eyeLook.x, y: centre.y + eyeLook.y), right: i == 1, frame: frame, color: color, t: t, in: &context)
        }
        drawMouth(p, color: color, in: &context)
        if p.cheeks > 0.03 {
            let k = min(p.cheeks / 0.6, 1)
            for x in [20.0, 76.0] {
                let w = 6 + 4 * k, h = 2.6 + 2 * k
                context.fill(Path(ellipseIn: CGRect(x: x - w / 2, y: 40 - h / 2, width: w, height: h)), with: .color(cheek.opacity(0.45 + 0.45 * k)))
            }
        }
        for sprite in live.sprites where sprite.attached { drawSprite(sprite, color: color, in: &context) }
        var props = world
        for sprite in live.sprites where !sprite.attached { drawSprite(sprite, color: color, in: &props) }
    }

    private static func drawEye(at c: CGPoint, right: Bool, frame: FaceMotion.Frame, color: Color, t: TimeInterval, in context: inout GraphicsContext) {
        let p = frame.pose, live = frame.live
        if p.shape != .capsule {
            let s = 9.5 * frame.pop * live.eyeScale
            var shaped = context
            shaped.translateBy(x: c.x, y: c.y)
            if p.shape == .star { shaped.rotate(by: .radians(live.eyeSpin)) }
            let path = p.shape == .heart ? heart(.zero, s) : star(.zero, s * 1.15)
            shaped.fill(path, with: .color(color))
            if p.shape == .heart {
                shaped.fill(Path(ellipseIn: CGRect(x: -s * 0.45, y: -s * 0.5, width: s * 0.38, height: s * 0.26)), with: .color(.white.opacity(0.9)))
            }
            return
        }
        var open = frame.blink
        if right { open = min(open, 1 - p.winkRight * 0.96) }
        open = min(open, 1 - p.closed * 0.96)
        // Negative `close` opens shut eyes for a moment (jerking awake).
        open = live.close >= 0 ? min(open, 1 - live.close * 0.96) : max(open, -live.close)
        let w = 8 * p.eyeWidth * live.eyeScale * (open < 1 ? frame.squash : 1)
        let h = max(1.3, 10 * p.eyeHeight * live.eyeScale * open)

        // Shut eyes read better as a soft ‿ line than as a flat sliver.
        if open < 0.2 {
            var arc = Path()
            arc.move(to: CGPoint(x: c.x - 7, y: c.y - 1))
            arc.addQuadCurve(to: CGPoint(x: c.x + 7, y: c.y - 1), control: CGPoint(x: c.x, y: c.y + 5))
            context.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            return
        }
        let rect = CGRect(x: c.x - w, y: c.y - h, width: w * 2, height: h * 2)
        var eye = context
        eye.clip(to: Path(roundedRect: rect, cornerRadius: min(w, h)))
        // Lids cut the eye instead of painting black over it, so edges stay clean on any background.
        if p.smile > 0.02 {
            // A wide ellipse rising from below leaves an upturned crescent: happy eyes.
            let top = c.y + h * (1.2 - 1.45 * p.smile)
            eye.clip(to: Path(ellipseIn: CGRect(x: c.x - w * 1.3, y: top, width: w * 2.6, height: h * 2.6)), options: .inverse)
        }
        if p.lid > 0.02 {
            // Top lid with slant: sad droops outward, determined tilts inward.
            let top = c.y - h - 2, cut = h * 2 * p.lid, slope = p.lidSlant * (right ? 1 : -1) * h * 0.6
            var lid = Path()
            lid.move(to: CGPoint(x: c.x - w - 3, y: top))
            lid.addLine(to: CGPoint(x: c.x + w + 3, y: top))
            lid.addLine(to: CGPoint(x: c.x + w + 3, y: top + cut - slope))
            lid.addLine(to: CGPoint(x: c.x - w - 3, y: top + cut + slope))
            lid.closeSubpath()
            eye.clip(to: lid, options: .inverse)
        }
        eye.fill(Path(rect), with: .color(color))
        // Highlight, drifting a little with the gaze.
        if h > 4, p.smile < 0.5 {
            let hl = CGRect(x: c.x - w * 0.55 + frame.glance.x * 0.3, y: c.y - h * 0.72 + h * 2 * p.lid * 0.8, width: w * 0.45, height: min(h * 0.35, 5))
            eye.fill(Path(roundedRect: hl, cornerRadius: 2), with: .color(.white.opacity(0.95)))
        }
    }

    private static func drawMouth(_ p: FacePose, color: Color, in context: inout GraphicsContext) {
        let y = 44.0, half = 6 * p.mouthWidth
        if p.oh > 0.25 {
            let k = p.oh
            context.fill(Path(ellipseIn: CGRect(x: 48 - 2.6 * k, y: y + 1 - 3.4 * k, width: 5.2 * k, height: 6.8 * k)), with: .color(color))
        } else if p.mouthOpen > 0.2 {
            let open = p.mouthOpen
            var m = Path()
            m.move(to: CGPoint(x: 48 - half, y: y - 1))
            m.addQuadCurve(to: CGPoint(x: 48 + half, y: y - 1), control: CGPoint(x: 48, y: y + 9 * open))
            m.closeSubpath()
            context.fill(m, with: .color(color))
            context.fill(Path(ellipseIn: CGRect(x: 45.4, y: y + 1.6 * open, width: 5.2, height: 3.2 * open)), with: .color(FaceScene.pink.opacity(0.9)))
        } else {
            var m = Path()
            m.move(to: CGPoint(x: 48 - half, y: y))
            m.addQuadCurve(to: CGPoint(x: 48 + half, y: y), control: CGPoint(x: 48, y: y + p.mouth * 6))
            context.stroke(m, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        }
    }

    private static func drawSprite(_ s: FaceSprite, color: Color, in context: inout GraphicsContext) {
        guard s.opacity > 0.01, s.size > 0.3 else { return }
        var s = s
        // Props stay inside the face box, which the notch clips.
        switch s.kind {
        case .symbol, .text, .circle, .drop, .bars:
            let r = s.size / 2
            s.at.x = min(max(s.at.x, r + 1), 95 - r)
            s.at.y = min(max(s.at.y, r + 1), 59 - r)
        case .ring:
            s.size = min(s.size, 2 * min(s.at.x, 96 - s.at.x, s.at.y, 60 - s.at.y))
        case .line:
            break
        }
        var layer = context
        layer.opacity = s.opacity
        layer.translateBy(x: s.at.x, y: s.at.y)
        layer.rotate(by: .radians(s.angle))
        let tint = s.color ?? color
        switch s.kind {
        case .symbol(let name):
            var image = layer.resolve(Image(systemName: name))
            image.shading = .color(tint)
            // Keep the symbol's own proportions inside a `size` box.
            let natural = image.size
            let fit = s.size / max(natural.width, natural.height, 1)
            let w = natural.width * fit, h = natural.height * fit
            layer.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        case .text(let text):
            let resolved = layer.resolve(Text(text).font(.system(size: s.size, weight: .heavy, design: .rounded)).foregroundColor(tint))
            layer.draw(resolved, at: .zero, anchor: .center)
        case .circle:
            layer.fill(Path(ellipseIn: CGRect(x: -s.size / 2, y: -s.size / 2, width: s.size, height: s.size)), with: .color(tint))
        case .ring(let width):
            layer.stroke(Path(ellipseIn: CGRect(x: -s.size / 2, y: -s.size / 2, width: s.size, height: s.size)), with: .color(tint), lineWidth: width)
        case .line(let to, let width):
            var line = Path()
            line.move(to: .zero)
            line.addLine(to: CGPoint(x: to.x - s.at.x, y: to.y - s.at.y))
            layer.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: width, lineCap: .round))
        case .drop:
            let r = s.size / 2
            var drop = Path()
            drop.move(to: CGPoint(x: 0, y: -r * 1.8))
            drop.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: r * 0.9, y: -r * 0.9))
            drop.addArc(center: .zero, radius: r, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
            drop.addQuadCurve(to: CGPoint(x: 0, y: -r * 1.8), control: CGPoint(x: -r * 0.9, y: -r * 0.9))
            layer.fill(drop, with: .color(tint))
        case .bars(let levels):
            let w = s.size / Double(levels.count * 2 - 1)
            for (i, level) in levels.enumerated() {
                let h = s.size * level
                let x = -s.size / 2 + Double(i) * w * 2
                layer.fill(Path(roundedRect: CGRect(x: x, y: -h / 2, width: w, height: h), cornerRadius: w / 2), with: .color(tint))
            }
        }
    }

    private static func heart(_ c: CGPoint, _ s: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y + s * 0.9))
        p.addCurve(to: CGPoint(x: c.x, y: c.y - s * 0.35), control1: CGPoint(x: c.x - s * 1.3, y: c.y), control2: CGPoint(x: c.x - s * 0.9, y: c.y - s))
        p.addCurve(to: CGPoint(x: c.x, y: c.y + s * 0.9), control1: CGPoint(x: c.x + s * 0.9, y: c.y - s), control2: CGPoint(x: c.x + s * 1.3, y: c.y))
        return p
    }

    /// Four-point sparkle.
    private static func star(_ c: CGPoint, _ s: CGFloat) -> Path {
        var p = Path()
        let k = s * 0.28
        p.move(to: CGPoint(x: c.x, y: c.y - s))
        p.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x - k, y: c.y - k))
        return p
    }
}

/// The companion face: drawn live, springs between moods and plays a little scene for each.
struct FaceView: View {
    let mood: Mood
    var look: CGPoint = .zero
    var scale: CGFloat = 0.5
    var color: Color = FacePalette.oled.color
    /// Fixed scene time, for previews and tests.
    var sceneTime: TimeInterval? = nil

    @State private var motion = FaceMotion()
    @ObservedObject private var tempo = AppEnvironment.shared.tempo
    @ObservedObject private var breathing = AppEnvironment.shared.breathing
    @ObservedObject private var energy = EnergyPolicy.shared

    var body: some View {
        let size = CGSize(width: FaceGeometry.size.width * scale, height: FaceGeometry.size.height * scale)
        let reduced = energy.state.reducedEffects
        Group {
            if energy.state.suspended || sceneTime != nil {
                canvas(at: Date(), lively: false)
            } else {
                TimelineView(FaceSchedule(motion: motion, fast: reduced ? 1 / 12 : 1 / 30, slow: reduced ? 1 / 2 : 1 / 8)) { ctx in
                    canvas(at: ctx.date, lively: !reduced)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: color.opacity(0.45), radius: 2 * max(scale * 2, 1))
        .accessibilityHidden(true)
    }

    private func canvas(at date: Date, lively: Bool) -> some View {
        let dance = danceMotion(at: date)
        let breath: Double? = mood == .breathe && breathing.isActive ? breathing.state(at: date).fullness : nil
        let start = sceneTime.map { date.addingTimeInterval(-$0) }
        return Canvas { context, size in
            if let start { _ = motion.advance(to: start, mood: mood, lively: false) }
            let frame = motion.advance(to: date, mood: mood, lively: lively && dance == nil)
            SoftFaceRenderer.draw(frame, in: &context, size: size, color: color, time: date.timeIntervalSinceReferenceDate,
                                  look: look, dance: dance, breath: breath)
        }
    }

    /// Bounces on the beat: quiet songs sway, loud fast ones jump and squash on landing.
    private func danceMotion(at date: Date) -> (lift: Double, sway: Double, squash: Double)? {
        guard mood == .music, let bpm = tempo.tempo?.bpm, let beats = tempo.beats(at: date) else { return nil }
        let level = tempo.audio.isLive ? Double(tempo.audio.levels().energy) : 0.5
        let drive = min(max((bpm - 80) / 60 * 0.5 + level * 0.5, 0), 1)
        let phase = beats.truncatingRemainder(dividingBy: 1)
        let hop = sin(phase * .pi)
        let lift = hop * (1 + drive * 4)
        let sway = sin(beats * .pi / 2) * (0.04 + (1 - drive) * 0.06)
        let squash = 1 - max(0, 0.12 - phase * 0.6) * drive * 1.5
        return (lift, sway, squash)
    }
}
