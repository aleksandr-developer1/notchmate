import Foundation
import Darwin

/// Intercept only when the current Codex turn explicitly identifies a human reviewer.
enum CodexReview {
    static func isUser(_ payload: [String: Any]) -> Bool {
        guard let path = payload["transcript_path"] as? String, path.hasPrefix("/"),
              let session = payload["session_id"] as? String, !session.isEmpty,
              let turn = payload["turn_id"] as? String, !turn.isEmpty else { return false }
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let size = try? file.seekToEnd(),
              (try? file.seek(toOffset: 0)) != nil,
              let header = try? file.read(upToCount: 64 << 10), let firstLine = header.split(separator: 10).first,
              let first = try? JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
              first["type"] as? String == "session_meta",
              let meta = first["payload"] as? [String: Any], meta["id"] as? String == session,
              (try? file.seek(toOffset: size > 8 << 20 ? size - (8 << 20) : 0)) != nil,
              let data = try? file.readToEnd(), data.last == 10 else { return false }
        var lines = data.split(separator: 10)
        if size > 8 << 20 { lines = Array(lines.dropFirst()) }
        let rows = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        guard rows.count == lines.count,
              let last = rows.last(where: { $0["type"] as? String == "turn_context" }),
              let context = last["payload"] as? [String: Any], context["turn_id"] as? String == turn else { return false }
        return context["approvals_reviewer"] as? String == "user"
    }
}
