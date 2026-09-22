import AVFoundation
import Foundation
import Speech

/// On-device speech-to-text. Tries, in order:
/// 1. macOS 26 SpeechAnalyzer (best, but only ~30 locales — no Russian as of 26.5),
/// 2. classic Apple recogniser with on-device models, in chunks,
/// 3. whisper.cpp, if it and a model are installed.
enum Transcriber {
    struct Progress: Sendable { let done: Int; let total: Int }

    static func transcribe(_ url: URL, locale localeID: String, onProgress: @escaping @Sendable (Progress) -> Void) async throws -> String {
        let locale = Locale(identifier: localeID)
        // whisper gives by far the best Russian, so it goes first whenever a model is installed.
        if whisperBinary != nil, whisperModel != nil, let text = try whisper(url, locale: localeID), !text.isEmpty { return text }
        if #available(macOS 26.0, *), await modernSupports(locale) {
            if let text = try? await modern(url, locale: locale), !text.isEmpty { return text }
        }
        if let text = try? await apple(url, locale: locale, onProgress: onProgress), !text.isEmpty { return text }
        if let text = try whisper(url, locale: localeID), !text.isEmpty { return text }
        throw AIError.message(String(localized: "Не удалось расшифровать: для «\(localeID)» нет распознавания на устройстве. Включите язык в Системных настройках → Клавиатура → Диктовка, или поставьте модель whisper."))
    }

    // MARK: 1. macOS 26 engine

    @available(macOS 26.0, *)
    private static func modernSupports(_ locale: Locale) async -> Bool {
        let wanted = locale.identifier(.bcp47).lowercased().prefix(2)
        return await SpeechTranscriber.supportedLocales.contains { $0.identifier(.bcp47).lowercased().hasPrefix(wanted) }
    }

    @available(macOS 26.0, *)
    private static func modern(_ url: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let source = try AVAudioFile(forReading: url)
        // The analyzer wants its own format — convert if the file doesn't match.
        var file = source
        if let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]), best != source.processingFormat {
            file = try convert(source, to: best)
        }
        let collector = Task { () -> String in
            var parts: [String] = []
            for try await result in transcriber.results { parts.append(String(result.text.characters)) }
            return parts.joined(separator: " ")
        }
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 2. Classic Apple recogniser, chunked

    private static func apple(_ url: URL, locale: Locale, onProgress: @escaping @Sendable (Progress) -> Void) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw AIError.message(String(localized: "Распознавание для этого языка недоступно"))
        }
        let status = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard status == .authorized else { throw AIError.message(String(localized: "Нет разрешения на распознавание речи")) }
        guard recognizer.supportsOnDeviceRecognition else {
            throw AIError.message(String(localized: "Для «\(locale.identifier)» нет офлайн-модели — скачайте язык в Системных настройках → Клавиатура → Диктовка"))
        }

        let chunks = try split(url, seconds: 50)
        defer { chunks.forEach { try? FileManager.default.removeItem(at: $0) } }
        var parts: [String] = []
        for (i, chunk) in chunks.enumerated() {
            onProgress(Progress(done: i, total: chunks.count))
            let text = try await recognizeFile(chunk, recognizer: recognizer)
            if !text.isEmpty { parts.append(text) }
        }
        onProgress(Progress(done: chunks.count, total: chunks.count))
        return parts.joined(separator: " ")
    }

    private static func recognizeFile(_ url: URL, recognizer: SFSpeechRecognizer) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.taskHint = .dictation
            nonisolated(unsafe) var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    cont.resume(throwing: error)
                } else if let result, result.isFinal {
                    finished = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    // MARK: 3. whisper.cpp

    static var whisperBinary: URL? {
        ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"].map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    static var whisperModel: URL? {
        let candidates = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchMate/models"),
            URL(fileURLWithPath: NSHomeDirectory() + "/my_project/AI dialog/.models"),
        ]
        let preferred = ["ggml-large-v3-turbo.bin", "ggml-large-v3-turbo-q5_0.bin", "ggml-large-v3-turbo-q8_0.bin", "ggml-medium.bin", "ggml-small.bin", "ggml-base.bin", "ggml-tiny.bin"]
        for dir in candidates {
            for name in preferred {
                let url = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private static func whisper(_ url: URL, locale: String) throws -> String? {
        guard let binary = whisperBinary, let model = whisperModel else { return nil }
        let out = url.deletingPathExtension()
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-m", model.path, "-f", url.path, "-l", String(locale.prefix(2)),
                             "-otxt", "-of", out.path, "-nt", "-t", "6"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let txt = out.appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: txt) }
        return try? String(contentsOf: txt, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Audio helpers

    /// Splits a file into WAV chunks the classic recogniser can chew on.
    private static func split(_ url: URL, seconds: Double) throws -> [URL] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        // Buffers handed to AVAudioFile must be in its processing format (float32); the file itself stores 16-bit PCM.
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let fileSettings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000.0,
                                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                                           AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                                           AVLinearPCMIsNonInterleaved: false]
        let converter = AVAudioConverter(from: format, to: target)
        let dir = url.deletingLastPathComponent().appendingPathComponent("chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        let framesPerChunk = AVAudioFrameCount(seconds * format.sampleRate)
        var index = 0
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(min(Int64(framesPerChunk), file.length - file.framePosition))
            guard remaining > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining) else { break }
            try file.read(into: buffer, frameCount: remaining)
            guard buffer.frameLength > 0 else { break }
            let chunkURL = dir.appendingPathComponent(String(format: "chunk-%03d.wav", index))
            let output = try AVAudioFile(forWriting: chunkURL, settings: fileSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            if let converter {
                let ratio = target.sampleRate / format.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
                guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
                var supplied = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if supplied { status.pointee = .endOfStream; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                converter.reset()
                if let error { throw error }
                try output.write(from: converted)
            } else {
                try output.write(from: buffer)
            }
            urls.append(chunkURL)
            index += 1
        }
        return urls
    }

    private static func convert(_ file: AVAudioFile, to format: AVAudioFormat) throws -> AVAudioFile {
        let url = file.url.deletingLastPathComponent().appendingPathComponent("analyzer.wav")
        try? FileManager.default.removeItem(at: url)
        let output = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format) else { return file }
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate * 30)
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(min(Int64(chunk), file.length - file.framePosition))
            guard remaining > 0, let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining) else { break }
            try file.read(into: input, frameCount: remaining)
            guard input.frameLength > 0 else { break }
            let ratio = format.sampleRate / file.processingFormat.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024) else { break }
            var supplied = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if supplied { status.pointee = .endOfStream; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            converter.reset()
            if let error { throw error }
            try output.write(from: out)
        }
        return try AVAudioFile(forReading: url)
    }
}
