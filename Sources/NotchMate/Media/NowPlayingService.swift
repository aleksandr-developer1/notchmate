import AppKit
import SwiftUI

struct NowPlayingTrack: Equatable {
    var title: String
    var artist: String
    var album: String
    var bundleID: String
    var duration: Double          // seconds
    var elapsed: Double           // seconds at `timestamp`
    var timestamp: Date
    var rate: Double
    var isPlaying: Bool
    var isLiked: Bool?
    var shuffle: Int?
    var repeatMode: Int?

    var identity: String { "\(title)|\(artist)|\(bundleID)" }

    func elapsed(at date: Date) -> Double {
        guard isPlaying else { return min(elapsed, duration > 0 ? duration : elapsed) }
        let value = elapsed + date.timeIntervalSince(timestamp) * max(rate, 1)
        return duration > 0 ? min(max(0, value), duration) : max(0, value)
    }
}

enum MediaCommand: Int {
    case play = 0, pause = 1, toggle = 2, stop = 3, next = 4, previous = 5
    case toggleShuffle = 6, toggleRepeat = 7, back15 = 12, skip15 = 13
}

/// Streams "Now Playing" through ungive/mediaremote-adapter, which runs inside
/// Apple-signed /usr/bin/perl and so passes the macOS 15.4+ entitlement check.
@MainActor
final class NowPlayingService: ObservableObject {
    @Published private(set) var track: NowPlayingTrack?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color = Color(red: 1, green: 0.8, blue: 0.2)
    @Published private(set) var isAvailable = true

    /// Fires on a new track (not on pause/resume).
    var onTrackChange: ((NowPlayingTrack) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var lastArtworkString: String?
    private var restartDelay: TimeInterval = 1
    private var stopped = false
    private var clearWorkItem: DispatchWorkItem?

    private var scriptURL: URL? { Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl") ?? devURL("bin/mediaremote-adapter.pl") }
    private var frameworkURL: URL? { Bundle.main.url(forResource: "MediaRemoteAdapter", withExtension: "framework") ?? devURL("build/MediaRemoteAdapter.framework") }

    private func devURL(_ rel: String) -> URL? {
        // Allows `swift run` from the repo root.
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Vendor/mediaremote-adapter").appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func start() {
        stopped = false
        launchStream()
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
    }

    private func launchStream() {
        guard !stopped, let script = scriptURL, let framework = frameworkURL else {
            isAvailable = false
            return
        }
        Self.killOrphanedStreams(script: script.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path, "stream", "--no-diff", "--micros", "--debounce=80"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.consume(chunk) }
            }
        }
        p.terminationHandler = { [weak self] _ in
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    let delay = self.restartDelay
                    self.restartDelay = min(self.restartDelay * 2, 30)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.launchStream() }
                }
            }
        }
        do {
            try p.run()
            process = p
            isAvailable = true
        } catch {
            isAvailable = false
        }
    }

    /// A previous NotchMate that was killed (rebuild, crash) leaves its perl stream behind — clean those up.
    private static func killOrphanedStreams(script: String) {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "\(script) .* stream"]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()
    }

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  (obj["type"] as? String) == "data" else { continue }
            restartDelay = 1
            apply(obj["payload"] as? [String: Any] ?? [:])
        }
    }

    private func apply(_ p: [String: Any]) {
        guard let title = p["title"] as? String, !title.isEmpty else {
            // Players briefly report empty state while switching tracks — debounce clearing.
            clearWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.track = nil
                self?.artwork = nil
                self?.lastArtworkString = nil
            }
            clearWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
            return
        }
        clearWorkItem?.cancel()

        func num(_ k: String) -> Double? { (p[k] as? NSNumber)?.doubleValue }
        let ts = num("timestampEpochMicros").map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date()
        let new = NowPlayingTrack(
            title: title,
            artist: p["artist"] as? String ?? "",
            album: p["album"] as? String ?? "",
            bundleID: p["parentApplicationBundleIdentifier"] as? String ?? p["bundleIdentifier"] as? String ?? "",
            duration: (num("durationMicros") ?? 0) / 1_000_000,
            elapsed: (num("elapsedTimeMicros") ?? 0) / 1_000_000,
            timestamp: ts,
            rate: num("playbackRate") ?? 1,
            isPlaying: p["playing"] as? Bool ?? false,
            isLiked: p["isLiked"] as? Bool,
            shuffle: (p["shuffleMode"] as? NSNumber)?.intValue,
            repeatMode: (p["repeatMode"] as? NSNumber)?.intValue
        )
        let changed = track?.identity != new.identity
        track = new

        if let art = p["artworkData"] as? String {
            if art != lastArtworkString {
                lastArtworkString = art
                if let data = Data(base64Encoded: art), let img = NSImage(data: data) {
                    artwork = img
                    accent = Color(nsColor: img.vibrantColor())
                }
            }
        } else if changed {
            artwork = nil
            lastArtworkString = nil
            accent = Color(red: 1, green: 0.8, blue: 0.2)
        }
        if changed { onTrackChange?(new) }
    }

    // MARK: Commands

    func send(_ command: MediaCommand) {
        // Optimistic UI for play/pause.
        if var t = track {
            let now = Date()
            switch command {
            case .toggle:
                t.elapsed = t.elapsed(at: now); t.timestamp = now; t.isPlaying.toggle(); track = t
            case .play:
                t.elapsed = t.elapsed(at: now); t.timestamp = now; t.isPlaying = true; track = t
            case .pause:
                t.elapsed = t.elapsed(at: now); t.timestamp = now; t.isPlaying = false; track = t
            default: break
            }
        }
        runOnce(["send", String(command.rawValue)])
    }

    func seek(to seconds: Double) {
        if var t = track {
            t.elapsed = seconds; t.timestamp = Date(); track = t
        }
        runOnce(["seek", String(Int(seconds * 1_000_000))])
    }

    private func runOnce(_ args: [String]) {
        guard let script = scriptURL, let framework = frameworkURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [script.path, framework.path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: Source app

    static let yandexBundleIDs = ["ru.yandex.desktop.music", "ru.yandex.music", "com.yandex.music"]

    var sourceAppURL: URL? {
        guard let id = track?.bundleID, !id.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    var sourceAppName: String {
        guard let url = sourceAppURL else { return "" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var isYandex: Bool {
        guard let id = track?.bundleID else { return false }
        return Self.yandexBundleIDs.contains(id) || id.lowercased().contains("yandex")
    }

    func openSourceApp() {
        guard let url = sourceAppURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    static var yandexAppURL: URL? {
        for id in yandexBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        for name in ["Яндекс Музыка.app", "Yandex Music.app"] {
            for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
                let path = dir + "/" + name
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    static func launchYandexMusic() {
        if let url = yandexAppURL {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else if let web = URL(string: "https://music.yandex.ru/home") {
            NSWorkspace.shared.open(web)
        }
    }
}

extension NSImage {
    /// A vivid, readable accent color from the image.
    func vibrantColor() -> NSColor {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return .systemYellow }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        var best: (score: CGFloat, color: NSColor)? = nil
        var avg = (r: CGFloat(0), g: CGFloat(0), b: CGFloat(0))
        for x in 0..<side {
            for y in 0..<side {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                avg.r += c.redComponent; avg.g += c.greenComponent; avg.b += c.blueComponent
                let s = c.saturationComponent, b = c.brightnessComponent
                let score = s * 1.4 + b * 0.6 - abs(b - 0.75)
                if b > 0.25, best == nil || score > best!.score { best = (score, c) }
            }
        }
        let n = CGFloat(side * side)
        var color = best?.color ?? NSColor(red: avg.r / n, green: avg.g / n, blue: avg.b / n, alpha: 1)
        if color.saturationComponent < 0.12 { color = NSColor(red: avg.r / n, green: avg.g / n, blue: avg.b / n, alpha: 1) }
        // Make it readable on black.
        return NSColor(hue: color.hueComponent,
                       saturation: min(color.saturationComponent * 1.1, 0.85),
                       brightness: max(color.brightnessComponent, 0.8), alpha: 1)
    }
}
