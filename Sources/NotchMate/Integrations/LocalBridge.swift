import Foundation
import Network

/// Tiny HTTP server on 127.0.0.1 so helper processes (agent hooks, the MCP server) can talk to the running app.
/// Port and a random bearer token are written to a user-only file.
@MainActor
final class LocalBridge {
    nonisolated static var infoURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchMate/bridge.json")
    }

    var onEvent: (([String: Any]) -> Void)?
    var onTool: ((String, [String: Any]) async -> (text: String, isError: Bool))?

    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: params)
        } catch {
            NSLog("NotchMate bridge: cannot create listener: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
            return
        }
        listener.stateUpdateHandler = { [weak self] state in
            NSLog("NotchMate bridge state: \(String(describing: state))")
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.writeInfo(port: port) } }
                }
            case .failed, .waiting:
                listener.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { self?.start() } }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.accept(conn) } }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func writeInfo(port: UInt16) {
        let url = Self.infoURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json: [String: Any] = ["port": Int(port), "token": token, "pid": Int(ProcessInfo.processInfo.processIdentifier)]
        if let data = try? JSONSerialization.data(withJSONObject: json) {
            FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    var buf = buffer
                    if let data { buf.append(data) }
                    if let request = HTTPRequest.parse(buf) {
                        Task { @MainActor in await self.handle(request, conn) }
                    } else if done || error != nil || buf.count > 4 << 20 {
                        conn.cancel()
                    } else {
                        self.receive(conn, buffer: buf)
                    }
                }
            }
        }
    }

    private func handle(_ req: HTTPRequest, _ conn: NWConnection) async {
        guard req.headers["authorization"] == "Bearer \(token)" else {
            respond(conn, status: 401, json: ["error": "unauthorized"]); return
        }
        let body = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
        switch (req.method, req.path) {
        case ("POST", "/event"):
            onEvent?(body)
            respond(conn, status: 200, json: ["ok": true])
        case ("POST", "/tool"):
            let name = body["name"] as? String ?? ""
            let args = body["arguments"] as? [String: Any] ?? [:]
            let result: (text: String, isError: Bool) = await onTool?(name, args) ?? (text: "NotchMate не готов", isError: true)
            respond(conn, status: 200, json: ["text": result.text, "isError": result.isError])
        default:
            respond(conn, status: 404, json: ["error": "not found"])
        }
    }

    private func respond(_ conn: NWConnection, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var head = "HTTP/1.1 \(status) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if status != 200 { head = head.replacingOccurrences(of: " OK", with: " ERR") }
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = sep.upperBound
        guard data.count - bodyStart >= length else { return nil }
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers,
                           body: data.subdata(in: bodyStart..<(bodyStart + length)))
    }
}

/// Client side used by the helper modes (no UI, runs before NSApplication).
enum BridgeClient {
    static func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        guard let data = try? Data(contentsOf: LocalBridge.infoURL),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = info["port"] as? Int, let token = info["token"] as? String,
              let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data { result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 1)
        return result
    }
}
