import AppKit
import SwiftUI

enum FacePalette: String, CaseIterable, Identifiable {
    case oled, mint, white, pink, amber
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .oled: return Color(red: 0.84, green: 0.96, blue: 1.0)
        case .mint: return Color(red: 0.55, green: 1.0, blue: 0.86)
        case .white: return Color(white: 0.97)
        case .pink: return Color(red: 1.0, green: 0.66, blue: 0.84)
        case .amber: return Color(red: 1.0, green: 0.8, blue: 0.35)
        }
    }
    var title: String {
        switch self {
        case .oled: return "OLED"
        case .mint: return String(localized: "Мятный")
        case .white: return String(localized: "Белый")
        case .pink: return String(localized: "Розовый")
        case .amber: return String(localized: "Янтарный")
        }
    }
}

/// Frame animations of the companion face: 128×64 1-bit clips drawn by tools/draw_faces.py.
@MainActor
final class FaceAnimations {
    static let shared = FaceAnimations()

    struct Clip {
        let frames: [NSImage]
        let blush: [NSImage]?   // separate layer, drawn in red
        let fps: Double
    }

    static let blushColor = Color(red: 1.0, green: 0.36, blue: 0.47)

    static let width = 128, height = 64
    /// Crop that contains the face in every clip (x 16..<112, y 2..<62).
    static let crop = CGRect(x: 16, y: 2, width: 96, height: 60)

    private(set) var clips: [String: Clip] = [:]

    private init() {
        let url = Bundle.main.url(forResource: "face-animations", withExtension: "json")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/face-animations.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return }
        for (name, info) in json {
            guard let b64 = info["data"] as? String, let raw = Data(base64Encoded: b64),
                  let count = info["count"] as? Int else { continue }
            let fps = (info["fps"] as? NSNumber)?.doubleValue ?? 8
            let frameSize = Self.width * Self.height / 8
            func decode(_ data: Data) -> [NSImage] {
                (0..<count).compactMap { i in
                    guard data.count >= (i + 1) * frameSize else { return nil }
                    return Self.image(from: data.subdata(in: (i * frameSize)..<((i + 1) * frameSize)))
                }
            }
            let blush = (info["blush"] as? String).flatMap { Data(base64Encoded: $0) }.map(decode)
            clips[name] = Clip(frames: decode(raw), blush: blush, fps: fps)
        }
    }

    private static func image(from bits: Data) -> NSImage? {
        let cw = Int(crop.width), ch = Int(crop.height)
        var rgba = [UInt8](repeating: 0, count: cw * ch * 4)
        bits.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for y in 0..<ch {
                for x in 0..<cw {
                    let sx = x + Int(crop.minX), sy = y + Int(crop.minY)
                    let i = sy * width + sx
                    if (buf[i / 8] >> (7 - UInt8(i % 8))) & 1 == 1 {
                        let o = (y * cw + x) * 4
                        rgba[o] = 255; rgba[o + 1] = 255; rgba[o + 2] = 255; rgba[o + 3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: cw, height: ch, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cw * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cw, height: ch))
        img.isTemplate = true
        return img
    }

    /// Every mood has its own clip; only the wake-up story plays once.
    static func segment(for mood: Mood) -> (clip: String, range: Range<Int>?, loops: Bool) {
        (mood.rawValue, nil, mood != .startup)
    }

    /// Dance clips are one bar (4 beats) long; frame 0 of each beat lands on the beat.
    /// Sets by the character of the rhythm: slow/quiet → nod and sway, mid → bob, fast/loud → bob and jump.
    static let danceMoves: [[String]] = [
        ["dance_nod", "dance_sway", "dance_nod", "dance_sway"],
        ["dance_bob", "dance_sway", "dance_bob", "dance_nod"],
        ["dance_bob", "dance_jump", "dance_bob", "dance_jump", "dance_sway"],
    ]

    /// Clip and frame for a beat position; the move changes every two bars.
    /// `bpm` and live `energy` (0…1) pick the set, so a ballad and a banger dance differently.
    func dance(beats: Double, bpm: Double, energy: Double) -> (clip: Clip, index: Int)? {
        let b = max(beats, 0)
        let drive = (bpm - 80) / 60 * 0.5 + energy * 0.5     // ~0 slow & quiet … ~1 fast & loud
        let set = Self.danceMoves[drive < 0.35 ? 0 : (drive < 0.65 ? 1 : 2)]
        let move = set[Int(b / 8) % set.count]
        guard let clip = clips[move], !clip.frames.isEmpty else { return nil }
        let phase = b.truncatingRemainder(dividingBy: 4) / 4
        return (clip, min(Int(phase * Double(clip.frames.count)), clip.frames.count - 1))
    }
}

/// Animated companion face. `scale` = points per OLED pixel (0.5 → crisp 1:1 on Retina).
struct FaceView: View {
    let mood: Mood
    var look: CGPoint = .zero
    var scale: CGFloat = 0.5
    var color: Color = FacePalette.oled.color

    @State private var startDate = Date()
    /// Observed so the face starts dancing as soon as the track's tempo arrives.
    @ObservedObject private var tempo = AppEnvironment.shared.tempo
    @ObservedObject private var breathing = AppEnvironment.shared.breathing

    var body: some View {
        let seg = FaceAnimations.segment(for: mood)
        let clip = FaceAnimations.shared.clips[seg.clip]
        let size = CGSize(width: FaceAnimations.crop.width * scale, height: FaceAnimations.crop.height * scale)
        let dancing = mood == .music && tempo.tempo != nil
        // Dancing needs ~30 fps so a 12-frame beat stays smooth up to 150 BPM; everything else keeps the clip's rate.
        let synced = dancing || (mood == .breathe && breathing.isActive)
        TimelineView(.animation(minimumInterval: synced ? 1 / 30 : 1 / (clip?.fps ?? 8),
                                paused: !synced && (clip?.frames.count ?? 0) <= 1)) { ctx in
            if mood == .breathe, breathing.isActive, let clip, !clip.frames.isEmpty {
                // Frame = how full the lungs are, so holds freeze naturally.
                let full = breathing.state(at: ctx.date).fullness
                frame(clip, min(Int((full * Double(clip.frames.count - 1)).rounded()), clip.frames.count - 1), size: size)
            } else if dancing, let beats = tempo.beats(at: ctx.date), let bpm = tempo.tempo?.bpm {
                // Clip follows the beat grid; the live energy only picks which set of moves to dance.
                let energy = tempo.audio.isLive ? Double(tempo.audio.levels().energy) : 0.5
                if let move = FaceAnimations.shared.dance(beats: beats, bpm: bpm, energy: energy) {
                    frame(move.clip, move.index, size: size)
                }
            } else if let clip, !clip.frames.isEmpty {
                let t = ctx.date.timeIntervalSince(startDate)
                let range = seg.range.map { $0.clamped(to: 0..<clip.frames.count) } ?? 0..<clip.frames.count
                let n = max(range.count, 1)
                let step = Int(t * clip.fps)
                frame(clip, range.lowerBound + (seg.loops ? step % n : min(step, n - 1)), size: size)
            } else {
                Text(String(localized: "Пикси")).font(Theme.font(10, .bold)).foregroundStyle(color)
            }
        }
        .frame(width: size.width, height: size.height)
        .offset(x: look.x * 3.5 * max(scale * 2, 1), y: look.y * 2 * max(scale * 2, 1))
        .onChange(of: mood) { _, _ in startDate = Date() }
    }

    private func frame(_ clip: FaceAnimations.Clip, _ idx: Int, size: CGSize) -> some View {
        ZStack {
            if let blush = clip.blush, blush.indices.contains(idx) {
                Image(nsImage: blush[idx])
                    .renderingMode(.template).interpolation(.none).resizable()
                    .foregroundStyle(FaceAnimations.blushColor)
                    .shadow(color: FaceAnimations.blushColor.opacity(0.9), radius: 2.5 * max(scale * 2, 1))
            }
            Image(nsImage: clip.frames[idx])
                .renderingMode(.template).interpolation(.none).resizable()
                .foregroundStyle(color)
                .shadow(color: color.opacity(0.6), radius: 2.5 * max(scale * 2, 1))
        }
        .frame(width: size.width, height: size.height)
    }
}
