import AppKit
import SwiftUI

struct GitFile: Identifiable, Equatable {
    enum Kind { case staged, modified, untracked, conflict }
    let path: String
    let code: String      // two-letter porcelain code, e.g. "M.", ".D", "??"
    let kind: Kind
    var id: String { code + path }
}

struct GitStatus: Equatable {
    var root: String
    var branch: String = ""
    var detached = false
    var upstream: String?
    var ahead = 0
    var behind = 0
    var files: [GitFile] = []
    var lastCommit: (hash: String, subject: String, when: String)?
    var remoteURL: String?

    var name: String { (root as NSString).lastPathComponent }
    var staged: Int { files.filter { $0.kind == .staged }.count }
    var modified: Int { files.filter { $0.kind == .modified }.count }
    var untracked: Int { files.filter { $0.kind == .untracked }.count }
    var conflicts: Int { files.filter { $0.kind == .conflict }.count }
    var isClean: Bool { files.isEmpty }
    var isGitHub: Bool { remoteURL?.contains("github.com") ?? false }

    /// https URL of the repository page, from an ssh or https remote.
    var webURL: URL? {
        guard var s = remoteURL else { return nil }
        if s.hasPrefix("git@") { s = "https://" + s.dropFirst(4).replacingOccurrences(of: ":", with: "/") }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return URL(string: s)
    }

    static func == (a: GitStatus, b: GitStatus) -> Bool {
        a.root == b.root && a.branch == b.branch && a.detached == b.detached && a.upstream == b.upstream
            && a.ahead == b.ahead && a.behind == b.behind && a.files == b.files
            && a.lastCommit?.hash == b.lastCommit?.hash && a.remoteURL == b.remoteURL
    }
}

/// Pull request / CI state from the GitHub CLI.
struct GitCI: Equatable {
    enum State: Equatable { case none, pending, success, failure }
    var state: State = .none
    var title: String = ""          // workflow or PR title
    var url: URL?
    var prNumber: Int?
    var review: String?             // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED
    var failedCheck: String?
    var checksDone = 0
    var checksTotal = 0
}

/// Git in the notch: the repository you're working in, its changes, CI, and AI commit messages.
@MainActor
final class GitService: ObservableObject {
    @Published private(set) var status: GitStatus?
    @Published private(set) var ci = GitCI()
    @Published private(set) var recent: [String] = []
    /// Chosen by hand in the tab — auto-detection doesn't override it until another dev app is focused.
    @Published private(set) var pinned = false
    @Published private(set) var ghAvailable = false
    @Published var commitMessage = ""
    @Published private(set) var generating = false
    @Published private(set) var busy: String?          // "commit", "push", "pull"
    @Published var lastError: String?
    @Published private(set) var lastResult: String?

    private weak var env: AppEnvironment?
    private var timer: Timer?
    private var tickCount = 0
    private var detecting = false
    private var refreshing = false
    private var generateTask: Task<Void, Never>?

    var root: String? { status?.root }

    func start(env: AppEnvironment) {
        self.env = env
        recent = (UserDefaults.standard.stringArray(forKey: "gitRecentRepos") ?? []).filter { RepoDetector.gitRoot($0) != nil }
        ghAvailable = Git.gh != nil
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, let app, RepoDetector.isDevApp(app.bundleIdentifier) else { return }
                self.pinned = false
                self.detect()
            }
        }
        // Git status can be costly in large working trees. Refresh promptly while its tab is
        // visible, but keep the background watcher deliberately quiet.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if let first = recent.first { select(first, pin: false) }
        detect()
    }

    private func tick() {
        guard Settings.shared.gitEnabled, let env else { return }
        tickCount += 1
        let front = NSWorkspace.shared.frontmostApplication
        let devFront = RepoDetector.isDevApp(front?.bundleIdentifier)
        let watching = env.notchIsOpen(on: .git)
        // App activation already triggers immediate detection. Polling is only a fallback while
        // a developer app remains in front.
        if devFront, !pinned, tickCount % 6 == 0 { detect() }
        // Local status: every 5 s while looking at the Git tab; every 30 s in a dev app and
        // every two minutes otherwise.
        if watching || (devFront && tickCount % 6 == 0) || tickCount % 24 == 0 { refresh() }
        // CI: every 30 s while looking, every five minutes otherwise.
        if Settings.shared.gitCIEnabled, ghAvailable, tickCount % (watching ? 6 : 60) == 0 { refreshCI() }
    }

    // MARK: Repository

    func detect() {
        guard Settings.shared.gitEnabled, !detecting,
              let app = NSWorkspace.shared.frontmostApplication, RepoDetector.isDevApp(app.bundleIdentifier) else { return }
        detecting = true
        let pid = app.processIdentifier, bundleID = app.bundleIdentifier ?? ""
        let title = RepoDetector.focusedWindowTitle(pid: pid)
        let known = recent
        Task.detached(priority: .utility) {
            let found = RepoDetector.detect(pid: pid, bundleID: bundleID, windowTitle: title, known: known)
            await MainActor.run {
                self.detecting = false
                if let found, found != self.root, !self.pinned { self.select(found, pin: false) }
            }
        }
    }

    /// Agents report their working directory through hooks — a good hint when no terminal is in front.
    func noteAgentDirectory(_ dir: String) {
        guard Settings.shared.gitEnabled, let root = RepoDetector.gitRoot(dir) else { return }
        if recent.first != root { remember(root) }
        if status == nil { select(root, pin: false) }
    }

    func select(_ root: String, pin: Bool = true) {
        pinned = pin
        guard root != self.root else { return }
        remember(root)
        status = GitStatus(root: root)
        ci = GitCI()
        commitMessage = ""
        lastError = nil
        lastResult = nil
        refresh()
        refreshCI()
    }

    func forget(_ root: String) {
        recent.removeAll { $0 == root }
        UserDefaults.standard.set(recent, forKey: "gitRecentRepos")
    }

    private func remember(_ root: String) {
        recent.removeAll { $0 == root }
        recent.insert(root, at: 0)
        recent = Array(recent.prefix(8))
        UserDefaults.standard.set(recent, forKey: "gitRecentRepos")
    }

    // MARK: Status

    func refresh() {
        guard let root, !refreshing else { return }
        refreshing = true
        Task {
            let next = await Git.status(root)
            refreshing = false
            guard let next, next.root == self.root else { return }
            if let old = status, !old.branch.isEmpty, old.root == next.root, old.branch != next.branch {
                branchChanged(to: next.branch)
            }
            if next != status { withAnimation(.spring(response: 0.35)) { status = next } }
        }
    }

    private func branchChanged(to branch: String) {
        commitMessage = ""
        ci = GitCI()
        env?.notch?.showHUD(.message(icon: "arrow.triangle.branch", text: branch), duration: 2)
        refreshCI()
    }

    // MARK: CI

    func refreshCI() {
        guard Settings.shared.gitCIEnabled, ghAvailable, let s = status, s.isGitHub, !s.branch.isEmpty, !s.detached else { return }
        let branch = s.branch
        Task {
            guard let next = await Git.ci(root: s.root, branch: branch), self.root == s.root, self.status?.branch == branch else { return }
            let old = ci
            if next != old { withAnimation(.spring(response: 0.35)) { ci = next } }
            react(old: old, new: next, repo: s.name)
        }
    }

    /// The face reacts to CI and review changes (only transitions, not the first load).
    private func react(old: GitCI, new: GitCI, repo: String) {
        guard let env, old.state != .none || old.prNumber != nil else { return }
        let companion = env.companion
        if old.state == .pending, new.state == .failure {
            companion.notify(.sad, badge: CompanionBadge(symbol: "xmark.octagon.fill", image: nil, tint: .red), seconds: 4)
            companion.say(String(localized: "CI упал\(new.failedCheck.map { ": \($0)" } ?? "") 💥"), force: true)
            env.attention.gitCIFailed(repo: repo, ci: new)
        } else if old.state == .pending, new.state == .success {
            companion.notify(.proud, badge: CompanionBadge(symbol: "checkmark.seal.fill", image: nil, tint: .green), seconds: 3)
            companion.say(String(localized: "CI зелёный ✅ \(repo)"))
        }
        if new.review != old.review, let review = new.review, old.prNumber == new.prNumber {
            switch review {
            case "APPROVED":
                companion.notify(.love, badge: CompanionBadge(symbol: "hand.thumbsup.fill", image: nil, tint: .green), seconds: 3)
                companion.say(String(localized: "PR #\(new.prNumber ?? 0) одобрили 🎉"), force: true)
            case "CHANGES_REQUESTED":
                companion.notify(.surprised, badge: CompanionBadge(symbol: "text.bubble.fill", image: nil, tint: .orange), seconds: 3)
                companion.say(String(localized: "В PR #\(new.prNumber ?? 0) просят правки ✍️"), force: true)
            default: break
            }
        }
    }

    // MARK: Actions

    func generateMessage() {
        guard let env, let s = status, !generating else { return }
        guard env.ai.isReady(env.ai.provider) else {
            lastError = String(localized: "Подключите ИИ в настройках")
            return
        }
        generating = true
        lastError = nil
        generateTask = Task {
            defer { generating = false }
            let context = await Git.commitContext(s.root, stagedOnly: s.staged > 0)
            guard !context.diff.isEmpty else { lastError = String(localized: "Нет изменений"); return }
            let system = """
            You write git commit messages. Reply with the commit message only: no quotes, no markdown fences, no explanations.
            First line: imperative summary, at most 72 characters. If the change is non-trivial, add a blank line and 1–4 short bullet lines.
            Match the language and the style (e.g. Conventional Commits prefixes) of the recent commit subjects when there are any.
            """
            let prompt = """
            Recent commit subjects:
            \(context.recent.isEmpty ? "(none)" : context.recent)

            Branch: \(s.branch)
            Changed files:
            \(context.stat)

            Diff:
            \(context.diff)
            """
            do {
                var text = try await env.ai.oneShot(prompt: prompt, system: system)
                if text.hasPrefix("```") {
                    text = text.components(separatedBy: "\n").filter { !$0.hasPrefix("```") }.joined(separator: "\n")
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { commitMessage = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            } catch {
                lastError = String(localized: "ИИ: \(error.localizedDescription)")
            }
        }
    }

    func commit() {
        guard let s = status, busy == nil else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { lastError = String(localized: "Напишите сообщение коммита"); return }
        run("commit") {
            if s.staged == 0 {
                let add = await Git.run(["add", "-A"], in: s.root)
                if add.code != 0 { return add }
            }
            return await Git.run(["commit", "-F", "-"], in: s.root, stdin: message)
        } success: { [weak self] _ in
            self?.commitMessage = ""
            self?.lastResult = String(localized: "Закоммичено")
            self?.env?.companion.react(.proud, for: 2.5)
        }
    }

    func push() {
        guard let s = status, busy == nil else { return }
        let args = s.upstream == nil ? ["push", "-u", "origin", "HEAD"] : ["push"]
        run("push") { await Git.run(args, in: s.root, timeout: 90) } success: { [weak self] _ in
            self?.lastResult = String(localized: "Отправлено в \(s.upstream ?? "origin/\(s.branch)")")
            self?.env?.companion.react(.excited, for: 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self?.refreshCI() }
        }
    }

    func pull() {
        guard let s = status, busy == nil else { return }
        run("pull") { await Git.run(["pull", "--ff-only"], in: s.root, timeout: 90) } success: { [weak self] out in
            self?.lastResult = out.contains("Already up to date") ? String(localized: "Уже актуально") : String(localized: "Подтянуто")
            self?.env?.companion.react(.nod, for: 1.4)
        }
    }

    private func run(_ name: String, _ work: @escaping () async -> Git.Result, success: @escaping (String) -> Void) {
        busy = name
        lastError = nil
        lastResult = nil
        Task {
            let r = await work()
            busy = nil
            if r.code == 0 {
                success(r.out)
            } else {
                let text = (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines)
                lastError = text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(2).joined(separator: " ")
                env?.companion.react(.sad, for: 2)
            }
            refresh()
        }
    }

    func openInTerminal() {
        guard let root else { return }
        let terminal = NSWorkspace.shared.runningApplications.first { RepoDetector.terminals.contains($0.bundleIdentifier ?? "") }
        let id = terminal?.bundleIdentifier ?? "com.apple.Terminal"
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: root)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    func openWeb() {
        if let url = ci.url ?? status?.webURL { NSWorkspace.shared.open(url) }
    }
}

// MARK: - Command line

enum Git {
    struct Result { let code: Int32; let out: String; let err: String }

    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    static let git: String = searchPaths.map { $0 + "/git" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    static var gh: String? { searchPaths.map { $0 + "/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static func run(_ args: [String], in dir: String, stdin: String? = nil, timeout: TimeInterval = 20, tool: String? = nil) async -> Result {
        let executable = tool ?? git
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: dir)
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
                env["GIT_OPTIONAL_LOCKS"] = "0"          // don't fight the user's own git for index.lock
                env["GIT_TERMINAL_PROMPT"] = "0"         // never hang waiting for a password
                env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
                env["GH_PROMPT_DISABLED"] = "1"
                env["NO_COLOR"] = "1"
                p.environment = env
                let out = Pipe(), err = Pipe(), inp = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = inp
                do { try p.run() } catch {
                    cont.resume(returning: Result(code: -1, out: "", err: error.localizedDescription))
                    return
                }
                if let stdin { inp.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inp.fileHandleForWriting.close()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { errData = err.fileHandleForReading.readAll(); group.leave() }
                let outData = out.fileHandleForReading.readAll()
                group.wait()
                p.waitUntilExit()
                killer.cancel()
                cont.resume(returning: Result(code: p.terminationStatus,
                                              out: String(decoding: outData, as: UTF8.self),
                                              err: String(decoding: errData, as: UTF8.self)))
            }
        }
    }

    static func status(_ root: String) async -> GitStatus? {
        async let st = run(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: root)
        async let log = run(["log", "-1", "--format=%h%x1f%s%x1f%cr"], in: root)
        async let remote = run(["remote", "get-url", "origin"], in: root)
        let (s, l, r) = await (st, log, remote)
        guard s.code == 0 else { return nil }

        var result = GitStatus(root: root)
        for line in s.out.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                let head = String(line.dropFirst(14))
                result.detached = head == "(detached)"
                result.branch = result.detached ? "detached" : head
            } else if line.hasPrefix("# branch.upstream ") {
                result.upstream = String(line.dropFirst(18))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst(12).split(separator: " ")
                if parts.count == 2 {
                    result.ahead = Int(parts[0].dropFirst()) ?? 0
                    result.behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                // 1 XY sub mH mI mW hH hI path  |  2 XY sub mH mI mW hH hI Xscore path<TAB>orig
                let fields = line.split(separator: " ", maxSplits: line.hasPrefix("1 ") ? 8 : 9, omittingEmptySubsequences: false)
                guard fields.count >= 9 else { continue }
                let xy = Array(fields[1])
                let path = String(fields.last!.split(separator: "\t").first ?? "")
                let code = String(fields[1])
                if xy[0] != "." { result.files.append(GitFile(path: path, code: code, kind: .staged)) }
                if xy[1] != "." { result.files.append(GitFile(path: path, code: code, kind: .modified)) }
            } else if line.hasPrefix("u ") {
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if let path = fields.last { result.files.append(GitFile(path: String(path), code: String(fields[1]), kind: .conflict)) }
            } else if line.hasPrefix("? ") {
                result.files.append(GitFile(path: String(line.dropFirst(2)), code: "??", kind: .untracked))
            }
        }
        let logParts = l.out.trimmingCharacters(in: .newlines).components(separatedBy: "\u{1f}")
        if l.code == 0, logParts.count == 3 { result.lastCommit = (logParts[0], logParts[1], logParts[2]) }
        if r.code == 0 { result.remoteURL = r.out.trimmingCharacters(in: .whitespacesAndNewlines) }
        return result
    }

    struct CommitContext { let diff: String; let stat: String; let recent: String }

    static func commitContext(_ root: String, stagedOnly: Bool) async -> CommitContext {
        let base = stagedOnly ? ["diff", "--staged"] : ["diff", "HEAD"]
        async let diff = run(base + ["--no-ext-diff", "-U2"], in: root)
        async let stat = run(base + ["--stat=100"], in: root)
        async let recent = run(["log", "-8", "--format=%s"], in: root)
        async let untracked = run(["ls-files", "--others", "--exclude-standard"], in: root)
        let (d, s, r, u) = await (diff, stat, recent, untracked)
        var diffText = d.out
        var statText = s.out
        if !stagedOnly, !u.out.isEmpty {
            let files = u.out.split(separator: "\n").prefix(30).map { "new file: \($0)" }.joined(separator: "\n")
            statText += "\n" + files
            if diffText.isEmpty { diffText = files }
        }
        // Keep prompts small: the stat tells the story for large changes.
        if diffText.count > 14_000 { diffText = String(diffText.prefix(14_000)) + "\n… (diff truncated)" }
        return CommitContext(diff: diffText, stat: statText, recent: r.out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// PR of the branch with its checks; without a PR — the latest workflow run of the branch.
    static func ci(root: String, branch: String) async -> GitCI? {
        guard let gh else { return nil }
        let pr = await run(["pr", "view", branch, "--json", "number,title,url,state,reviewDecision,statusCheckRollup"], in: root, timeout: 25, tool: gh)
        if pr.code == 0, let json = try? JSONSerialization.jsonObject(with: Data(pr.out.utf8)) as? [String: Any],
           (json["state"] as? String) == "OPEN" {
            var ci = GitCI()
            ci.prNumber = json["number"] as? Int
            ci.title = json["title"] as? String ?? ""
            ci.url = (json["url"] as? String).flatMap(URL.init(string:))
            ci.review = (json["reviewDecision"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let checks = json["statusCheckRollup"] as? [[String: Any]] ?? []
            ci.checksTotal = checks.count
            var pending = false, failed = false
            for c in checks {
                let name = c["name"] as? String ?? c["context"] as? String ?? "check"
                let status = c["status"] as? String            // CheckRun
                let conclusion = (c["conclusion"] as? String) ?? (c["state"] as? String) ?? ""   // CheckRun / StatusContext
                if let status, status != "COMPLETED" { pending = true; continue }
                if conclusion == "PENDING" || conclusion == "EXPECTED" { pending = true; continue }
                ci.checksDone += 1
                if ["FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"].contains(conclusion) {
                    failed = true
                    if ci.failedCheck == nil { ci.failedCheck = name }
                }
            }
            ci.state = checks.isEmpty ? .none : (failed ? .failure : (pending ? .pending : .success))
            return ci
        }
        let runs = await run(["run", "list", "--branch", branch, "--limit", "1", "--json", "status,conclusion,workflowName,displayTitle,url"],
                             in: root, timeout: 25, tool: gh)
        guard runs.code == 0 else { return nil }   // not signed in to gh, network — keep what we had
        guard let list = try? JSONSerialization.jsonObject(with: Data(runs.out.utf8)) as? [[String: Any]], let latest = list.first else { return GitCI() }
        var ci = GitCI()
        ci.title = latest["workflowName"] as? String ?? latest["displayTitle"] as? String ?? ""
        ci.url = (latest["url"] as? String).flatMap(URL.init(string:))
        let status = latest["status"] as? String ?? ""
        let conclusion = latest["conclusion"] as? String ?? ""
        if status != "completed" { ci.state = .pending }
        else if conclusion == "success" || conclusion == "skipped" || conclusion == "neutral" { ci.state = .success }
        else { ci.state = .failure; ci.failedCheck = ci.title }
        ci.checksTotal = 1
        ci.checksDone = status == "completed" ? 1 : 0
        return ci
    }
}
