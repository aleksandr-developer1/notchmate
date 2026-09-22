import Foundation

/// Detailed journal of the meeting assistant for later tuning: recogniser lifecycle, audio levels,
/// transcript, why a hint fired, the exact prompt, latency and answer. One JSON object per line in
/// ~/Library/Application Support/NotchMate/Calls/copilot-logs/<date>.jsonl. Stays on this Mac.
final class MeetingLog: @unchecked Sendable {
    static let shared = MeetingLog()

    private let queue = DispatchQueue(label: "notchmate.meetinglog")
    private var handle: FileHandle?
    private(set) var url: URL?
    private let started = Date()

    static var folder: URL {
        let dir = CallRecorder.recordingsFolder.appendingPathComponent("copilot-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// New file per session.
    func begin() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.folder.appendingPathComponent("copilot-\(f.string(from: Date())).jsonl")
        queue.sync {
            try? handle?.close()
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            self.url = url
        }
    }

    func write(_ event: String, _ fields: [String: Any] = [:]) {
        let now = Date()
        queue.async { [self] in
            if handle == nil { begin_locked() }
            var obj = fields
            obj["event"] = event
            obj["ts"] = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
            guard JSONSerialization.isValidJSONObject(obj),
                  var data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
            data.append(0x0A)
            handle?.write(data)
        }
    }

    private func begin_locked() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.folder.appendingPathComponent("copilot-\(f.string(from: Date())).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        self.url = url
    }
}
