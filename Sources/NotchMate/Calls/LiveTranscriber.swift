import AVFoundation
import Foundation
import Speech

/// Receives the call's audio buffers straight from the capture queues (see `CallRecorder`).
final class AudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: ((AVAudioPCMBuffer, Bool) -> Void)?

    func set(_ sink: ((AVAudioPCMBuffer, Bool) -> Void)?) {
        lock.lock(); self.sink = sink; lock.unlock()
    }

    func send(_ buffer: AVAudioPCMBuffer, isMic: Bool) {
        lock.lock(); let sink = self.sink; lock.unlock()
        sink?(buffer, isMic)
    }
}

/// Live on-device speech-to-text while a call is being recorded. macOS runs only one on-device
/// recognition task per app at a time — two tasks keep cancelling each other — so both sides
/// (my microphone and the other participants) are mixed into one 16 kHz stream first.
final class LiveTranscriber: @unchecked Sendable {
    /// Segment id, text so far, segment is final.
    typealias Update = (_ segment: String, _ text: String, _ final: Bool) -> Void

    private let recognizer: SFSpeechRecognizer
    private let onUpdate: Update
    private let onError: (String) -> Void
    private let queue = DispatchQueue(label: "notchmate.live")
    private static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    // Capture queues (one per source) touch only their own converter.
    private let micConverter = Converter()
    private let systemConverter = Converter()

    // Everything below lives on `queue`.
    private var mic: [Float] = []
    private var system: [Float] = []
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var segmentStarted = Date()
    private var heardSpeech = false
    private var running = true
    private var retryAfter = Date.distantPast
    private var quickFailures = 0
    private var micTotal = 0
    private var systemTotal = 0
    private var fedSamples = 0
    private var lastStats = Date.distantPast

    private static func rms(_ unused: [Float], of source: [Float], n: Int) -> Double {
        let count = min(n, source.count)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += source[i] * source[i] }
        return Double((sum / Float(count)).squareRoot())
    }

    init?(locale: String, onUpdate: @escaping Update, onError: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            onError(String(localized: "Распознавание для «\(locale)» недоступно"))
            return nil
        }
        guard recognizer.supportsOnDeviceRecognition else {
            onError(String(localized: "Для «\(locale)» нет офлайн-распознавания — скачайте язык в Системных настройках → Клавиатура → Диктовка"))
            return nil
        }
        self.recognizer = recognizer
        self.onUpdate = onUpdate
        self.onError = onError
    }

    static func authorize() async -> Bool {
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        return status == .authorized
    }

    func append(_ buffer: AVAudioPCMBuffer, isMic: Bool) {
        // Convert here: the capture buffer is reused after the callback returns.
        guard let samples = (isMic ? micConverter : systemConverter).convert(buffer, to: Self.target) else { return }
        queue.async { [self] in
            guard running else { return }
            if isMic { mic += samples; micTotal += samples.count } else { system += samples; systemTotal += samples.count }
            mix()
        }
    }

    func stop() {
        queue.async { [self] in
            running = false
            request?.endAudio()
            request = nil
            task?.finish()
            task = nil
        }
    }

    /// Mixes what both sources have delivered. A silent or missing source (microphone not captured)
    /// is padded with zeros once the other one is half a second ahead.
    private func mix() {
        let most = max(mic.count, system.count), least = min(mic.count, system.count)
        let n = least >= 1600 ? least : (most >= 8000 ? most : 0)
        guard n > 0 else { return }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<min(n, mic.count) { out[i] += mic[i] }
        for i in 0..<min(n, system.count) { out[i] += system[i] }
        fedSamples += n
        if Date().timeIntervalSince(lastStats) > 10 {
            lastStats = Date()
            MeetingLog.shared.write("audio_stats", ["mic_samples": micTotal, "system_samples": systemTotal, "fed_samples": fedSamples,
                                                    "mic_rms": Self.rms(out, of: mic, n: n), "system_rms": Self.rms(out, of: system, n: n),
                                                    "task_running": request != nil, "generation": generation])
        }
        mic.removeFirst(min(n, mic.count))
        system.removeFirst(min(n, system.count))
        feed(out)
    }

    private func feed(_ samples: [Float]) {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        var sum: Float = 0
        for (i, v) in samples.enumerated() {
            let clipped = max(-1, min(1, v))
            buffer.floatChannelData![0][i] = clipped
            sum += clipped * clipped
        }
        if request == nil {
            guard Date() >= retryAfter else { return }
            startTask()
        }
        request?.append(buffer)
        let level = (sum / Float(samples.count)).squareRoot()
        if level > 0.01 { heardSpeech = true }
        let age = Date().timeIntervalSince(segmentStarted)
        // Rotate on a pause (or every 40 s at most): long tasks slow down, short segments keep order.
        if (age > 12 && heardSpeech && level < 0.004) || age > 40 {
            MeetingLog.shared.write("recognizer_rotate", ["generation": generation, "age_s": age, "reason": age > 40 ? "max" : "pause"])
            request?.endAudio()
            request = nil
            startTask()
        }
    }

    private func startTask() {
        guard running else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = true
        req.addsPunctuation = true
        req.taskHint = .dictation
        generation += 1
        let gen = generation
        let segment = "seg\(gen)"
        let started = Date()
        request = req
        MeetingLog.shared.write("recognizer_start", ["generation": gen])
        segmentStarted = started
        heardSpeech = false
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.onUpdate(segment, result.bestTranscription.formattedString, result.isFinal)
                if result.isFinal {
                    MeetingLog.shared.write("recognizer_final", ["generation": gen, "lived_s": Date().timeIntervalSince(started),
                                                                 "text": result.bestTranscription.formattedString])
                }
            }
            if let error {
                let ns = error as NSError
                MeetingLog.shared.write("recognizer_error", ["generation": gen, "domain": ns.domain, "code": ns.code,
                                                             "message": ns.localizedDescription, "lived_s": Date().timeIntervalSince(started)])
            }
            guard error != nil || result?.isFinal == true else { return }
            self.queue.async {
                guard gen == self.generation, self.running else { return }
                self.request = nil
                if let error, Date().timeIntervalSince(started) < 1 {
                    // Fails right away — back off instead of spinning.
                    self.quickFailures += 1
                    self.retryAfter = Date().addingTimeInterval(min(10, Double(self.quickFailures)))
                    MeetingLog.shared.write("recognizer_backoff", ["failures": self.quickFailures])
                    if self.quickFailures == 5 {
                        self.onError(String(localized: "Живая расшифровка не запускается: \(error.localizedDescription)"))
                    }
                } else {
                    self.quickFailures = 0
                }
            }
        }
    }

    private final class Converter: @unchecked Sendable {
        private var converter: AVAudioConverter?

        func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> [Float]? {
            let format = buffer.format
            if converter == nil || converter?.inputFormat != format {
                converter = AVAudioConverter(from: format, to: target)
            }
            guard let converter else { return nil }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / format.sampleRate) + 256
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var supplied = false
            var error: NSError?
            // `.noDataNow` instead of end-of-stream keeps the resampler state between buffers.
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
        }
    }
}
