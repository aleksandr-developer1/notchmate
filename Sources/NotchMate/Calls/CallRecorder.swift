import AVFoundation
import AppKit
import CoreAudio
import ScreenCaptureKit
import Speech
import SwiftUI

/// Records calls locally: system audio + microphone → on-device transcript → AI summary → Obsidian note.
/// Nothing leaves the Mac except the summary request to the AI provider the user picked.
@MainActor
final class CallRecorder: NSObject, ObservableObject {
    enum Stage: Equatable { case idle, recording, transcribing, summarizing }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var startedAt: Date?
    @Published private(set) var lastNote: String?
    @Published private(set) var lastError: String?
    @Published private(set) var micActive = false
    /// Apps currently holding the microphone (NotchMate itself excluded).
    @Published private(set) var micApps: [String] = []
    private var micBusySince: Date?

    var onFinished: ((String, URL?) -> Void)?

    private weak var env: AppEnvironment?
    private let settings = Settings.shared
    private var stream: SCStream?
    private let writers = AudioWriters()
    private var folder: URL?
    private var title = String(localized: "Созвон")
    private var micIdleSince: Date?
    private var timer: Timer?
    /// Live audio for the meeting assistant (nothing is listening unless it's on).
    let tap = AudioTap()
    private lazy var output = StreamOutput(writers: writers, tap: tap)

    var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    func start(env: AppEnvironment) {
        self.env = env
        Task.detached { Self.removeEmptyPending() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    // MARK: Detection

    private func poll() {
        let holders = Self.microphoneHolders()
        let active = !holders.isEmpty
        micActive = active
        micApps = holders.map(\.name)
        // Same filters as auto-recording: only chosen apps / call sites count, not Siri or a voice memo.
        env?.companion.inCall = stage == .recording || isCallApp(holders) || env?.systemEvents.cameraActive == true
        if active {
            if micBusySince == nil { micBusySince = Date() }
            // Remember what uses the microphone so the settings can offer it in a list.
            var seen = settings.callsSeenApps
            for h in holders where !h.bundleID.isEmpty && seen[h.bundleID] == nil {
                seen[h.bundleID] = h.name
            }
            if seen.count != settings.callsSeenApps.count { settings.callsSeenApps = seen }
        } else {
            micBusySince = nil
        }

        guard settings.callsAutoRecord else { return }
        if active, stage == .idle, looksLikeCall(holders) {
            micIdleSince = nil
            Task { await beginRecording() }
        } else if !active, stage == .recording {
            if micIdleSince == nil { micIdleSince = Date() }
            if let since = micIdleSince, Date().timeIntervalSince(since) > 20 {
                Task { await finishRecording() }
            }
        } else if active {
            micIdleSince = nil
        }
    }

    /// True while another app records audio input. NotchMate's own capture is ignored —
    /// otherwise recording would keep itself alive forever.
    static func isMicrophoneInUse() -> Bool { !microphoneHolders().isEmpty }

    /// Bundle ids / names of apps recording audio input right now.
    static func microphoneHolders() -> [(bundleID: String, name: String)] {
        let me = pid_t(ProcessInfo.processInfo.processIdentifier)
        var holders: [(bundleID: String, name: String)] = []
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else {
            return holders
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr else {
            return holders
        }
        for object in objects {
            var runningAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &runningAddr, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }

            var pidAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &pidAddr, 0, nil, &pidSize, &pid) == noErr, pid != me else { continue }

            var bundleAddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
            // The HAL hands back a retained CFString.
            var cfBundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(object, &bundleAddr, 0, nil, &bundleSize, &cfBundle)
            let bundleID = (cfBundle?.takeRetainedValue() as String?) ?? ""
            let app = NSRunningApplication(processIdentifier: pid)
            // replayd is our own screen-capture helper doing the recording; CoreSpeech & co. listen for
            // "Hey Siri" / dictation. System daemons (no app behind the pid) are never a call.
            if bundleID == "com.apple.replayd" || bundleID.hasPrefix("com.apple.CoreSpeech")
                || bundleID == "com.apple.corespeechd" || bundleID == "com.apple.assistantd" { continue }
            if app == nil, bundleID.hasPrefix("com.apple.") { continue }
            holders.append((bundleID.isEmpty ? (app?.bundleIdentifier ?? "") : bundleID,
                            app?.localizedName ?? bundleID))
        }
        return holders
    }

    /// A call, not a voice message: a conferencing app (or a meeting in the calendar)
    /// holding the microphone for longer than a voice message would.
    private func looksLikeCall(_ holders: [(bundleID: String, name: String)]) -> Bool {
        let held = micBusySince.map { Date().timeIntervalSince($0) } ?? 0
        guard held >= Double(settings.callsMinSeconds) else { return false }
        if env?.calendar.events.contains(where: { $0.isNow }) == true { return true }
        return isCallApp(holders)
    }

    /// The microphone is held by a chosen call app or a browser with a call site open.
    private func isCallApp(_ holders: [(bundleID: String, name: String)]) -> Bool {
        guard !holders.isEmpty else { return false }
        // Chosen apps.
        if holders.contains(where: { settings.callsAppIDs.contains($0.bundleID) }) { return true }
        // A call open in a browser tab (Meet, Телемост, Zoom in the web…).
        if holders.contains(where: { BrowserTabs.isBrowser($0.bundleID) }) {
            let sites = settings.callsSites.map { $0.lowercased() }
            let urls = BrowserTabs.openURLs()
            if urls.contains(where: { url in sites.contains { url.lowercased().contains($0) } }) { return true }
        }
        return false
    }

    var micStatusText: String {
        guard !micApps.isEmpty else { return String(localized: "микрофон свободен") }
        return String(localized: "микрофон занят: ") + micApps.joined(separator: ", ")
    }

    // MARK: Recording

    func beginRecording() async {
        guard stage == .idle else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { throw AIError.message(String(localized: "Нет экрана для захвата звука")) }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            if #available(macOS 15.0, *), settings.callsCaptureMic {
                config.captureMicrophone = true
            }
            let dir = Self.recordingsFolder.appendingPathComponent(Self.stamp())
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            folder = dir
            title = env?.calendar.events.first { $0.isNow }?.title ?? Self.microphoneHolders().first?.name ?? String(localized: "Созвон")

            writers.open(system: dir.appendingPathComponent("system.caf"), mic: dir.appendingPathComponent("mic.caf"))
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "notchmate.audio"))
            if #available(macOS 15.0, *), settings.callsCaptureMic {
                try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "notchmate.mic"))
            }
            try await stream.startCapture()
            self.stream = stream
            startedAt = Date()
            stage = .recording
            lastError = nil
            env?.companion.react(.focused, for: 3)
        } catch {
            lastError = String(localized: "Запись не началась: \(error.localizedDescription)")
            stage = .idle
        }
    }

    /// Called on quit: stops the capture synchronously so the microphone is released.
    func shutdown() {
        guard let stream else { return }
        self.stream = nil
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            try? await stream.stopCapture()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 3)
        writers.close()
    }

    func cancelRecording() {
        Task {
            try? await stream?.stopCapture()
            stream = nil
            writers.close()
            if let folder { try? FileManager.default.removeItem(at: folder) }
            folder = nil
            startedAt = nil
            stage = .idle
        }
    }

    func finishRecording() async {
        guard stage == .recording else { return }
        let duration = elapsed
        try? await stream?.stopCapture()
        stream = nil
        writers.close()
        startedAt = nil
        guard let folder, duration >= 60 else {
            if let folder { try? FileManager.default.removeItem(at: folder) }
            self.folder = nil
            stage = .idle
            return
        }
        stage = .transcribing
        if await Task.detached(operation: { Self.isSilent(folder) }).value {
            discard(folder, reason: String(localized: "тишина"))
            return
        }
        do {
            let mixed = try await Task.detached { try Self.mixdown(in: folder) }.value
            let text = try await transcribe(mixed)
            guard text.count > 40 else {
                discard(folder, reason: String(localized: "речь не распознана"))
                return
            }
            try? text.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            stage = .summarizing
            let summary = try await summarize(text, duration: duration)
            let note = writeNote(summary: summary, transcript: text, duration: duration, folder: folder)
            lastNote = note
            onFinished?(title, nil)
            if !settings.callsKeepAudio { try? FileManager.default.removeItem(at: mixed) }
        } catch {
            lastError = error.localizedDescription
        }
        stage = .idle
        self.folder = nil
    }

    /// Finishes a recording whose audio is already on disk (NotchMate restarted mid-call).
    func processExisting(folder dir: URL, title: String? = nil) async {
        guard stage == .idle else { return }
        self.folder = dir
        self.title = title ?? String(localized: "Созвон")
        let seconds = Self.durationOfFiles(in: dir)
        self.startedAt = Date().addingTimeInterval(-seconds)
        stage = .transcribing
        let silent = seconds < 60 ? true : await Task.detached(operation: { Self.isSilent(dir) }).value
        if silent {
            discard(dir, reason: seconds < 60 ? String(localized: "короче минуты") : String(localized: "тишина"))
            startedAt = nil
            return
        }
        do {
            let mixed = try await Task.detached { try Self.mixdown(in: dir) }.value
            let text = try await transcribe(mixed)
            guard text.count > 40 else {
                discard(dir, reason: String(localized: "речь не распознана"))
                startedAt = nil
                return
            }
            try? text.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
            stage = .summarizing
            let summary = try await summarize(text, duration: seconds)
            lastNote = writeNote(summary: summary, transcript: text, duration: seconds, folder: dir)
            onFinished?(self.title, nil)
            if !settings.callsKeepAudio { try? FileManager.default.removeItem(at: mixed) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        stage = .idle
        startedAt = nil
        folder = nil
    }

    /// An empty recording is removed right away instead of leaving an error or a pending item behind.
    private func discard(_ dir: URL, reason: String) {
        try? FileManager.default.removeItem(at: dir)
        NSLog("NotchMate call: empty recording removed (\(reason)): \(dir.lastPathComponent)")
        MeetingLog.shared.write("recording_removed", ["folder": dir.lastPathComponent, "reason": reason])
        lastError = nil
        folder = nil
        stage = .idle
    }

    /// Leftovers of previous runs with nothing in them: shorter than a minute or silent.
    nonisolated static func removeEmptyPending() {
        for dir in pendingRecordings() {
            // Still being written by this run? Leave it.
            let modified = (try? dir.appendingPathComponent("system.caf").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) < 30 { continue }
            let seconds = durationOfFiles(in: dir)
            if seconds < 60 || isSilent(dir) {
                try? FileManager.default.removeItem(at: dir)
                NSLog("NotchMate call: empty pending recording removed: \(dir.lastPathComponent)")
            }
        }
    }

    /// True when neither track has a second of anything louder than background noise.
    nonisolated static func isSilent(_ dir: URL) -> Bool {
        for name in ["system.caf", "mic.caf"] {
            guard let file = try? AVAudioFile(forReading: dir.appendingPathComponent(name)) else { continue }
            let format = file.processingFormat
            let window = AVAudioFrameCount(format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: window) else { return false }
            var loudWindows = 0
            while file.framePosition < file.length {
                guard (try? file.read(into: buffer, frameCount: window)) != nil, buffer.frameLength > 0,
                      let data = buffer.floatChannelData else { break }
                var sum: Float = 0
                let n = Int(buffer.frameLength)
                for i in 0..<n { sum += data[0][i] * data[0][i] }
                if (sum / Float(n)).squareRoot() > 0.01 {
                    loudWindows += 1
                    if loudWindows >= 3 { return false }
                }
            }
        }
        return true
    }

    /// Unfinished recordings from a previous run — offered in the UI so nothing is lost.
    nonisolated static func pendingRecordings() -> [URL] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: recordingsFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return dirs.filter { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
            let hasAudio = fm.fileExists(atPath: url.appendingPathComponent("system.caf").path)
                || fm.fileExists(atPath: url.appendingPathComponent("mic.caf").path)
            let done = fm.fileExists(atPath: url.appendingPathComponent("transcript.txt").path)
            return hasAudio && !done
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    nonisolated static func durationOfFiles(in dir: URL) -> TimeInterval {
        for name in ["system.caf", "mic.caf"] {
            let url = dir.appendingPathComponent(name)
            if let f = try? AVAudioFile(forReading: url), f.fileFormat.sampleRate > 0 {
                return Double(f.length) / f.fileFormat.sampleRate
            }
        }
        return 0
    }

    // MARK: Audio plumbing

    nonisolated static var recordingsFolder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchMate/Calls", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm"
        return f.string(from: Date())
    }

    // Audio is written off the main thread: the sample buffers are only valid inside the callback.
    /// Mixes microphone + system audio into one 16 kHz mono file (what the recogniser wants).
    /// Runs ffmpeg for up to a minute on long calls — never on the main thread, or the whole app freezes.
    nonisolated private static func mixdown(in folder: URL) throws -> URL {
        let mic = folder.appendingPathComponent("mic.caf")
        let sys = folder.appendingPathComponent("system.caf")
        let out = folder.appendingPathComponent("call.wav")
        let fm = FileManager.default
        var inputs: [URL] = []
        if fm.fileExists(atPath: sys.path) { inputs.append(sys) }
        if fm.fileExists(atPath: mic.path) { inputs.append(mic) }
        guard !inputs.isEmpty else { throw AIError.message(String(localized: "Нет записанного звука")) }

        if let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { fm.isExecutableFile(atPath: $0) }) {
            var args: [String] = ["-loglevel", "error", "-y"]
            for i in inputs { args += ["-i", i.path] }
            // Speech in calls is often quiet — level it out, recognition depends on it.
            let loudnorm = "loudnorm=I=-16:TP=-1.5:LRA=11"
            if inputs.count == 2 {
                args += ["-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0,\(loudnorm)[a]", "-map", "[a]"]
            } else {
                args += ["-af", loudnorm]
            }
            args += ["-ar", "16000", "-ac", "1", out.path]
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0, fm.fileExists(atPath: out.path) { return out }
        }
        // Fallback: transcribe the system track as-is.
        return inputs[0]
    }

    // MARK: On-device transcription (macOS 26 Speech)

    @Published private(set) var progress: String?

    private func transcribe(_ url: URL) async throws -> String {
        let localeID = settings.callsLocale
        progress = nil
        defer { progress = nil }
        return try await Transcriber.transcribe(url, locale: localeID) { p in
            Task { @MainActor in
                self.progress = p.total > 1 ? "\(p.done)/\(p.total)" : nil
            }
        }
    }

    // MARK: Summary + note

    private func summarize(_ transcript: String, duration: TimeInterval) async throws -> String {
        guard let env else { throw AIError.message(String(localized: "Нет окружения")) }
        let prompt = """
        Ниже расшифровка рабочего созвона (распознавание речи, возможны ошибки). Сделай краткий протокол в Markdown. \(AppLanguage.replyInstruction) Заголовки разделов пиши на том же языке:

        **О чём говорили** — 3–6 пунктов.
        **Решения** — что решили.
        **Задачи** — списком «- [ ] задача — кто», если исполнитель понятен.
        **Открытые вопросы** — если есть.

        Без вступлений и воды. Если чего-то нет, раздел пропусти.

        Расшифровка:
        \(transcript.prefix(60000))
        """
        return try await env.ai.oneShot(prompt: prompt, system: "Ты делаешь точные протоколы рабочих встреч. \(AppLanguage.replyInstruction)",
                                        preferLocal: settings.callsSummaryLocalOnly)
    }

    private func writeNote(summary: String, transcript: String, duration: TimeInterval, folder: URL) -> String {
        guard let env, let vault = env.obsidian.vault else { return "" }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd HH-mm"
        let human = DateFormatter(); human.locale = AppLanguage.locale; human.setLocalizedDateFormatFromTemplate("dMMMMHHmm")
        let started = startedAt ?? Date().addingTimeInterval(-duration)
        let safeTitle = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let rel = "\(settings.callsFolder)/\(df.string(from: started)) \(safeTitle).md"
        let url = URL(fileURLWithPath: vault.path).appendingPathComponent(rel)
        let attendees = env.calendar.events.first { $0.start <= started && $0.end >= started }.map { String(localized: "\n**Событие:** \($0.title)") } ?? ""
        let body = """
        ---
        type: \(String(localized: "созвон"))
        date: \(ISO8601DateFormatter().string(from: started))
        duration: \(String(localized: "\(Int(duration / 60)) мин"))
        ---

        # \(title)

        **\(String(localized: "Когда:"))** \(human.string(from: started)) · \(String(localized: "\(Int(duration / 60)) мин"))\(attendees)
        **\(String(localized: "Запись:"))** \(String(localized: "локально")), [\(String(localized: "аудио и расшифровка"))](\(folder.path))

        \(summary)

        ---

        <details><summary>\(String(localized: "Расшифровка"))</summary>

        \(transcript)

        </details>
        """
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
            _ = env.obsidian.capture(String(localized: "Созвон «\(title)» (\(Int(duration / 60)) мин) — [[\((rel as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""))]]"))
            env.obsidian.refresh(force: true)
            return rel
        } catch {
            lastError = String(localized: "Заметка не сохранилась: \(error.localizedDescription)")
            return ""
        }
    }

    func openLastNote() {
        guard let rel = lastNote, !rel.isEmpty else { return }
        env?.obsidian.open(relativePath: rel)
    }
}

/// Writes both tracks from the capture queues; never touches the main actor.
private final class AudioWriters: @unchecked Sendable {
    private let lock = NSLock()
    private var system: AVAudioFile?
    private var mic: AVAudioFile?
    private var systemURL: URL?
    private var micURL: URL?

    func open(system systemURL: URL, mic micURL: URL) {
        lock.lock(); defer { lock.unlock() }
        self.systemURL = systemURL
        self.micURL = micURL
        system = nil
        mic = nil
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        system = nil
        mic = nil
        systemURL = nil
        micURL = nil
    }

    func append(_ buffer: AVAudioPCMBuffer, isMic: Bool) {
        lock.lock(); defer { lock.unlock() }
        do {
            let file: AVAudioFile?
            if isMic {
                if mic == nil, let url = micURL { mic = try Self.make(url: url, like: buffer) }
                file = mic
            } else {
                if system == nil, let url = systemURL { system = try Self.make(url: url, like: buffer) }
                file = system
            }
            try file?.write(from: buffer)
        } catch {
            NSLog("NotchMate call write: \(error)")
        }
    }

    private static func make(url: URL, like buffer: AVAudioPCMBuffer) throws -> AVAudioFile {
        var settings = buffer.format.settings
        settings[AVFormatIDKey] = kAudioFormatLinearPCM
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }
}

/// SCStream sample callbacks live outside the main actor.
private final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    let writers: AudioWriters
    let tap: AudioTap

    init(writers: AudioWriters, tap: AudioTap) {
        self.writers = writers
        self.tap = tap
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let isMic: Bool
        if #available(macOS 15.0, *) { isMic = type == .microphone } else { isMic = false }
        guard type == .audio || isMic else { return }
        // Convert here: the sample buffer is only valid for the duration of this call.
        guard let pcm = Self.pcm(from: sampleBuffer) else { return }
        writers.append(pcm, isMic: isMic)
        tap.send(pcm, isMic: isMic)
    }

    static func pcm(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = sample.formatDescription, var asbd = desc.audioStreamBasicDescription else { return nil }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(sample.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames),
                                                                 into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
