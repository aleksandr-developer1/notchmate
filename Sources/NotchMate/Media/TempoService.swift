import Combine
import Foundation

/// Tempo of the playing track. While it plays, AudioAnalyzer listens to the player and keeps the beat grid
/// in sync (following tempo changes); until it locks on, Deezer's catalogue BPM or the cached value is used.
/// Tapping the beat on the media card overrides everything. The grid is laid over the player's elapsed time.
@MainActor
final class TempoService: ObservableObject {
    enum Source: String, Codable { case catalogue, detected, tapped }

    struct Tempo: Codable, Equatable {
        var bpm: Double
        /// Track time (seconds) where a downbeat lands.
        var offset: Double
        var source: Source
    }

    /// nil while unknown (the face then plays the plain music clip).
    @Published private(set) var tempo: Tempo?
    /// Taps collected so far in the current tap-tempo run (for UI feedback).
    @Published private(set) var tapCount = 0

    /// Live audio: band levels and kick for the equalizer, face and glow.
    let audio = AudioAnalyzer()

    private weak var player: NowPlayingService?
    private var cancellable: AnyCancellable?
    private var playback: AnyCancellable?
    private var currentKey: String?
    private var lookup: Task<Void, Never>?
    private var taps: [Double] = []
    private var resetTaps: DispatchWorkItem?

    private static let cacheKey = "tempoCache"
    private var cache: [String: Tempo] = {
        guard let data = UserDefaults.standard.data(forKey: TempoService.cacheKey),
              let c = try? JSONDecoder().decode([String: Tempo].self, from: data) else { return [:] }
        return c
    }()

    func start(player: NowPlayingService) {
        self.player = player
        cancellable = player.$track
            // $track fires in willSet, so pass the new track along instead of reading player.track.
            .removeDuplicates { $0.map(Self.key) == $1.map(Self.key) }
            .sink { [weak self] track in self?.trackChanged(track) }
        playback = player.$track.sink { [weak self] track in self?.audio.follow(track) }
        audio.onGrid = { [weak self] grid in self?.apply(grid) }
    }

    /// Live estimate from the audio. Tapped tempo wins; small wobbles don't republish.
    private func apply(_ grid: AudioAnalyzer.Grid) {
        guard tempo?.source != .tapped, let key = currentKey, let track = player?.track, track.isPlaying else { return }
        let bpm = Self.fold(grid.bpm)
        let period = 60 / bpm
        let beatTime = track.elapsed(at: grid.beat)
        let offset = beatTime - (beatTime / period).rounded(.down) * period
        if let t = tempo, t.source == .detected, abs(t.bpm / bpm - 1) < 0.005 {
            var drift = abs(t.offset - offset).truncatingRemainder(dividingBy: period)
            drift = min(drift, period - drift)
            if drift < 0.03 { return }
            tempo = Tempo(bpm: t.bpm, offset: offset, source: .detected)
            return
        }
        store(Tempo(bpm: bpm, offset: offset, source: .detected), for: key)
    }

    /// Beats since the track's first downbeat, or nil if the tempo is unknown or nothing plays.
    func beats(at date: Date) -> Double? {
        guard let tempo, let track = player?.track, track.isPlaying, Self.key(track) == currentKey else { return nil }
        return (track.elapsed(at: date) - tempo.offset) * tempo.bpm / 60
    }

    // MARK: Tap tempo

    /// Tap along with the beat: 4+ taps set BPM and phase for this track.
    func tap() {
        guard let track = player?.track, let key = currentKey else { return }
        let now = Date()
        // Taps reset after a 2 s pause, so a new run starts clean and the counter doesn't hang.
        resetTaps?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.taps.removeAll(); self?.tapCount = 0 }
        resetTaps = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
        taps.append(track.elapsed(at: now))
        tapCount = taps.count
        guard taps.count >= 4 else { return }
        taps = Array(taps.suffix(12))
        let intervals = zip(taps.dropFirst(), taps).map { $0 - $1 }.filter { $0 > 0.2 && $0 < 2 }.sorted()
        guard !intervals.isEmpty else { return }
        let beat = intervals[intervals.count / 2]
        let bpm = Self.fold(60 / beat)
        let period = 60 / bpm
        // Average phase of all taps so one sloppy tap doesn't shift the grid.
        let angles = taps.map { $0.truncatingRemainder(dividingBy: period) / period * 2 * .pi }
        let phase = atan2(angles.map(sin).reduce(0, +), angles.map(cos).reduce(0, +))
        let offset = (phase < 0 ? phase + 2 * .pi : phase) / (2 * .pi) * period
        store(Tempo(bpm: bpm, offset: offset, source: .tapped), for: key)
    }

    // MARK: Lookup

    private func trackChanged(_ track: NowPlayingTrack?) {
        let key = track.map(Self.key)
        lookup?.cancel()
        audio.resetTempo()
        taps.removeAll()
        tapCount = 0
        currentKey = key
        guard let key, let track else { tempo = nil; return }
        if let cached = cache[key] { tempo = cached; return }
        tempo = nil
        let artist = track.artist, title = track.title
        lookup = Task { [weak self] in
            guard let bpm = await Self.catalogueBPM(artist: artist, title: title), !Task.isCancelled,
                  self?.tempo == nil else { return }
            self?.store(Tempo(bpm: Self.fold(bpm), offset: 0, source: .catalogue), for: key)
        }
    }

    private func store(_ tempo: Tempo, for key: String) {
        cache[key] = tempo
        if cache.count > 2000 { cache.removeValue(forKey: cache.keys.first!) }
        if let data = try? JSONEncoder().encode(cache) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
        if key == currentKey { self.tempo = tempo }
    }

    private static func key(_ t: NowPlayingTrack) -> String {
        "\(t.artist.lowercased())|\(t.title.lowercased())"
    }

    /// Dance-friendly range: 170 BPM reads as a 85 BPM groove.
    private static func fold(_ bpm: Double) -> Double {
        var b = bpm
        while b > 150 { b /= 2 }
        while b < 70 { b *= 2 }
        return b
    }

    /// "Get Lucky (feat. …) - Radio Edit" → "get lucky"
    private static func clean(_ s: String) -> String {
        var s = s.lowercased()
        for sep in [" (", " [", " - ", " feat", " ft."] {
            if let r = s.range(of: sep) { s = String(s[..<r.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func catalogueBPM(artist: String, title: String) async -> Double? {
        let q = "\(artist) \(clean(title))"
        guard var comps = URLComponents(string: "https://api.deezer.com/search") else { return nil }
        comps.queryItems = [.init(name: "q", value: q), .init(name: "limit", value: "5")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]] else { return nil }

        let wantArtist = artist.lowercased(), wantTitle = clean(title)
        let matches = results.filter { r in
            let a = ((r["artist"] as? [String: Any])?["name"] as? String ?? "").lowercased()
            let t = clean(r["title"] as? String ?? "")
            let artistOK = wantArtist.isEmpty || a.contains(wantArtist) || wantArtist.contains(a)
            return artistOK && (t == wantTitle || t.hasPrefix(wantTitle) || wantTitle.hasPrefix(t))
        }
        // Search results don't carry BPM; the track endpoint does (0 when unknown).
        for r in matches.prefix(3) {
            guard let id = (r["id"] as? NSNumber)?.intValue,
                  let url = URL(string: "https://api.deezer.com/track/\(id)"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let t = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bpm = (t["bpm"] as? NSNumber)?.doubleValue, bpm > 40 else { continue }
            return bpm
        }
        return nil
    }
}
