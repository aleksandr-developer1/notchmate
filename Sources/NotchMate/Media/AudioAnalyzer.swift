import Accelerate
import AVFoundation
import ScreenCaptureKit

/// Listens to the player's audio (ScreenCaptureKit, same permission as call recording) the whole time
/// a track plays: live band levels and kick strength for the equalizer, face and glow, plus a
/// sliding-window beat tracker so tempo changes inside a track are followed.
/// Cost: ~47 small FFTs per second on 12 kHz mono — well under 1% CPU.
@MainActor
final class AudioAnalyzer {
    struct Grid: Equatable {
        var bpm: Double
        /// Wall-clock moment a beat landed.
        var beat: Date
    }

    /// Called on the main actor when the beat grid is (re)estimated.
    var onGrid: ((Grid) -> Void)?

    private let meter = AudioMeter()
    private var stream: SCStream?
    private var bundleID: String?
    private var starting = false
    private var stopWork: DispatchWorkItem?

    init() {
        meter.onGrid = { [weak self] grid in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onGrid?(grid) } }
        }
    }

    /// Audio is flowing and recent (not paused, not silent for long).
    nonisolated var isLive: Bool { meter.snapshot().fresh }

    /// Latest levels: `bands` bass → treble (0…1, auto-gained), `kick` onset strength (0…1, decays fast).
    nonisolated func levels() -> (bands: [Float], kick: Float, energy: Float) {
        let s = meter.snapshot()
        return s.fresh ? (s.bands, s.kick, s.energy) : ([0, 0, 0, 0], 0, 0)
    }

    /// Calmer levels for glows: bass and kick eased in and out so the light swells instead of flickering.
    nonisolated func glowLevels() -> (bass: Float, kick: Float, energy: Float) {
        let s = meter.snapshot()
        return s.fresh ? (s.glowBass, s.glowKick, s.energy) : (0, 0, 0)
    }

    /// Starts listening while `track` plays, stops shortly after a pause.
    func follow(_ track: NowPlayingTrack?) {
        guard let track, track.isPlaying, !track.bundleID.isEmpty else {
            guard stream != nil, stopWork == nil else { return }
            // Short pauses and track switches shouldn't restart the capture.
            let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.stop() } }
            stopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            return
        }
        stopWork?.cancel()
        stopWork = nil
        if track.bundleID != bundleID { stop() }
        guard stream == nil, !starting else { return }
        start(bundleID: track.bundleID)
    }

    /// Forget the beat history (new track), keep the stream running.
    func resetTempo() { meter.resetTempo() }

    private func start(bundleID: String) {
        starting = true
        self.bundleID = bundleID
        let meter = self.meter
        Task {
            defer { starting = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                  let display = content.displays.first, self.bundleID == bundleID else { return }
            let filter: SCContentFilter
            if let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) {
                filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            } else {
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(meter, type: .audio, sampleHandlerQueue: DispatchQueue(label: "notchmate.audio-meter"))
                try await stream.startCapture()
            } catch {
                return
            }
            guard self.bundleID == bundleID else { try? await stream.stopCapture(); return }
            self.stream = stream
        }
    }

    private func stop() {
        stopWork?.cancel()
        stopWork = nil
        bundleID = nil
        guard let stream else { return }
        self.stream = nil
        meter.resetTempo()
        Task { try? await stream.stopCapture() }
    }
}

/// Runs on the audio queue: onset envelope (spectral flux), band levels and the beat tracker.
private final class AudioMeter: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Snapshot {
        var bands: [Float]
        var kick: Float
        var energy: Float
        var glowBass: Float
        var glowKick: Float
        var fresh: Bool
    }

    /// 48 kHz → 12 kHz; 1024-sample frames with hop 256 → ~47 envelope values per second.
    private static let decimation = 4
    private static let frameSize = 1024
    private static let hop = 256
    private static let fps = 48000.0 / Double(decimation) / Double(hop)
    /// Beat tracker window and how often it runs.
    private static let window = Int(fps * 8)
    private static let every = Int(fps * 1.5)
    /// Band edges in FFT bins (11.7 Hz each): bass, low-mid, mid, treble.
    private static let bandEdges = [2, 13, 51, 213, 512]

    var onGrid: ((AudioAnalyzer.Grid) -> Void)?

    private let lock = NSLock()
    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)
    private let hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
    private var carry: [Float] = []
    private var samples: [Float] = []
    private var previous = [Float](repeating: 0, count: frameSize / 2)

    // Beat tracking state.
    private var envelope: [Float] = []
    private var envelopeStart: Date?    // time of envelope[0]
    private var sinceAnalysis = 0
    private var grid: AudioAnalyzer.Grid?
    private var candidate: Double?

    // Live levels.
    private var bands: [Float] = [0, 0, 0, 0]
    private var bandPeaks: [Float] = [1e-3, 1e-3, 1e-3, 1e-3]
    private var kick: Float = 0
    private var bassFluxAvg: Float = 1e-3
    private var energy: Float = 0
    private var glowBass: Float = 0
    private var glowKick: Float = 0
    private var lastAudio = Date.distantPast

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(bands: bands, kick: kick, energy: energy, glowBass: glowBass, glowKick: glowKick, fresh: Date().timeIntervalSince(lastAudio) < 0.5)
    }

    func resetTempo() {
        lock.lock(); defer { lock.unlock() }
        envelope.removeAll()
        envelopeStart = nil
        grid = nil
        candidate = nil
        sinceAnalysis = 0
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let mono = Self.mono(sampleBuffer) else { return }
        // Presentation time is on the host clock; convert it to wall-clock.
        let lag = (CMClockGetTime(CMClockGetHostTimeClock()) - sampleBuffer.presentationTimeStamp).seconds
        let bufferStart = Date().addingTimeInterval(-max(0, lag))

        lock.lock()
        var newGrid: AudioAnalyzer.Grid?
        defer {
            lock.unlock()
            if let newGrid { onGrid?(newGrid) }
        }
        lastAudio = Date()
        if envelopeStart == nil {
            // Next envelope frame starts at samples[0]; an onset shows up around the frame's middle.
            let pending = Double(samples.count * Self.decimation + carry.count) / 48000
            envelopeStart = bufferStart.addingTimeInterval(-pending + Double(Self.frameSize / 2 * Self.decimation) / 48000)
        }
        carry += mono
        let usable = carry.count / Self.decimation * Self.decimation
        if usable > 0 {
            carry.withUnsafeBufferPointer { buf in
                for i in stride(from: 0, to: usable, by: Self.decimation) {
                    var sum: Float = 0
                    for j in 0..<Self.decimation { sum += buf[i + j] }
                    samples.append(sum / Float(Self.decimation))
                }
            }
            carry.removeFirst(usable)
        }
        while samples.count >= Self.frameSize {
            process(Array(samples[0..<Self.frameSize]))
            samples.removeFirst(Self.hop)
            sinceAnalysis += 1
        }
        // Keep a sliding window; shift its start time accordingly.
        if envelope.count > Self.window, let start = envelopeStart {
            let drop = envelope.count - Self.window
            envelope.removeFirst(drop)
            envelopeStart = start.addingTimeInterval(Double(drop) / Self.fps)
        }
        if sinceAnalysis >= Self.every, envelope.count >= Int(Self.fps * 5) {
            sinceAnalysis = 0
            newGrid = track()
        }
    }

    private func process(_ frame: [Float]) {
        guard let fft else { return }
        let n = Self.frameSize / 2
        let windowed = vDSP.multiply(frame, hann)
        var real = [Float](repeating: 0, count: n), imag = [Float](repeating: 0, count: n)
        var mags = [Float](repeating: 0, count: n)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBufferPointer { w in
                    w.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n)) }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n))
            }
        }
        // Log compression so quiet hi-hats count; flux = sum of positive changes per bin.
        let logMags = mags.map { log1p(100 * $0) }
        var flux: Float = 0, bassFlux: Float = 0
        for k in 1..<n {
            let d = max(0, logMags[k] - previous[k])
            flux += d
            if k < Self.bandEdges[1] { bassFlux += d }
        }
        previous = logMags
        envelope.append(flux)

        // Band levels with slow auto-gain (peaks fall ~5%/s), fast attack and softer release.
        var total: Float = 0
        for b in 0..<4 {
            var e: Float = 0
            for k in Self.bandEdges[b]..<Self.bandEdges[b + 1] { e += logMags[k] }
            e /= Float(Self.bandEdges[b + 1] - Self.bandEdges[b])
            bandPeaks[b] = max(e, bandPeaks[b] * 0.999)
            let level = min(1, e / bandPeaks[b])
            let shaped = pow(max(0, level - 0.35) / 0.65, 1.5)
            bands[b] += (shaped - bands[b]) * (shaped > bands[b] ? 0.7 : 0.25)
            total += e
        }
        energy += (min(1, total / max(bandPeaks.reduce(0, +), 1e-3)) - energy) * 0.05

        // Kick: bass flux well above its recent average.
        bassFluxAvg += (bassFlux - bassFluxAvg) * 0.02
        let hit = min(1, max(0, bassFlux / max(bassFluxAvg, 1e-3) - 1.3) / 2)
        kick = max(hit, kick * 0.8)

        // Glow: ~0.1 s rise, ~0.4 s fall.
        glowBass += (bands[0] - glowBass) * (bands[0] > glowBass ? 0.2 : 0.05)
        glowKick += (kick - glowKick) * (kick > glowKick ? 0.2 : 0.05)
    }

    /// Autocorrelation of the window picks the period (mild preference for ~120 BPM), a comb finds the phase.
    /// A tempo change is accepted only after two estimates agree, so one odd bar doesn't make the face jump.
    private func track() -> AudioAnalyzer.Grid? {
        guard let start = envelopeStart else { return nil }
        let fps = Self.fps
        let mean = envelope.reduce(0, +) / Float(envelope.count)
        let env = envelope.map { max(0, $0 - mean) }
        let energy = env.reduce(0) { $0 + $1 * $1 }
        guard energy > 0 else { return nil }

        let minLag = Int(fps * 60 / 180), maxLag = Int(fps * 60 / 60)
        guard maxLag + 1 < env.count else { return nil }
        let values: [Double] = (minLag...maxLag + 1).map { lag in
            var s: Float = 0
            vDSP_dotpr(env, 1, Array(env[lag...]), 1, &s, vDSP_Length(env.count - lag))
            return Double(s) / Double(env.count - lag)
        }
        var best = minLag, bestScore = -Double.infinity
        for lag in minLag...maxLag {
            let bpm = fps * 60 / Double(lag)
            var score = values[lag - minLag] * exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            // Stick to the current tempo when it's still plausible.
            if let g = grid, abs(bpm / g.bpm - 1) < 0.04 { score *= 1.25 }
            if score > bestScore { bestScore = score; best = lag }
        }
        let zero = Double(energy) / Double(env.count)
        guard values[best - minLag] / zero > 0.15 else { return nil }

        var period = Double(best)
        if best > minLag {
            let a = values[best - minLag - 1], b = values[best - minLag], c = values[best - minLag + 1]
            let d = a - 2 * b + c
            if d < 0 { period += 0.5 * (a - c) / d }
        }
        let bpm = fps * 60 / period

        if let g = grid, abs(bpm / g.bpm - 1) >= 0.04 {
            // Possible tempo change: wait for a second estimate that agrees.
            if let c = candidate, abs(bpm / c - 1) < 0.04 { candidate = nil } else { candidate = bpm; return nil }
        } else {
            candidate = nil
        }

        // Phase from the most recent 4 s, so it follows drift.
        let recent = max(0, env.count - Int(fps * 4))
        var bestPhase = 0.0, phaseScore = -Float.infinity
        for step in 0..<Int(period.rounded()) {
            var s: Float = 0
            var t = Double(recent + step)
            while t < Double(env.count - 1) {
                let i = Int(t.rounded())
                s += env[i] + 0.5 * (env[max(0, i - 1)] + env[min(env.count - 1, i + 1)])
                t += period
            }
            if s > phaseScore { phaseScore = s; bestPhase = Double(recent + step) }
        }
        let next = AudioAnalyzer.Grid(bpm: bpm, beat: start.addingTimeInterval(bestPhase / fps))
        grid = next
        return next
    }

    private static func mono(_ sample: CMSampleBuffer) -> [Float]? {
        guard let desc = sample.formatDescription, var asbd = desc.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                           into: buffer.mutableAudioBufferList) == noErr,
              let data = buffer.floatChannelData else { return nil }
        let channels = Int(format.channelCount), count = Int(frames)
        var out = [Float](repeating: 0, count: count)
        for c in 0..<channels {
            for i in 0..<count { out[i] += data[c][i] / Float(channels) }
        }
        return out
    }
}
