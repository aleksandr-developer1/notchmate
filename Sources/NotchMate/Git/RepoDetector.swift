import AppKit
import Darwin

/// Finds the git repository the user is working in right now, from the frontmost terminal or editor.
/// No permissions needed: it reads working directories of the app's child processes (same user).
/// Editors additionally use the window title when Accessibility is granted.
enum RepoDetector {
    static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty", "co.zeit.hyper", "com.raphaelamorim.rio",
    ]
    static let editors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "com.exafunction.windsurf", "com.apple.dt.Xcode", "com.sublimetext.4", "com.panic.Nova",
        "com.anthropic.claudefordesktop", "com.openai.codex",
    ]

    static func isDevApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return terminals.contains(id) || editors.contains(id) || id.hasPrefix("com.jetbrains.") || id == "com.google.android.studio"
    }

    /// Repository root for the app, or nil when it isn't showing a repository.
    /// `known` are repositories seen before — used to match editor window titles.
    static func detect(pid: pid_t, bundleID: String, windowTitle: String?, known: [String]) -> String? {
        let procs = descendants(of: pid)
        // Repositories open in this app: helper processes (language servers, integrated terminals, agents).
        var counts: [String: Int] = [:]
        for p in procs {
            guard let dir = cwd(p.pid), dir != "/", dir != NSHomeDirectory(), let root = gitRoot(dir) else { continue }
            counts[root, default: 0] += 1
        }
        // 1. Editors: a path or a project name in the focused window's title —
        //    tells apart several VS Code windows with different projects.
        if let title = windowTitle, !terminals.contains(bundleID) {
            let candidates = counts.keys.sorted { counts[$0]! > counts[$1]! } + known
            if let root = fromTitle(title, known: candidates) { return root }
        }
        // 2. The terminal tab (or integrated terminal) with the most recent input/output.
        if let root = fromActiveTTY(procs) { return root }
        // 3. Most common repository among helper processes.
        return counts.max { $0.value < $1.value }?.key
    }

    /// Walks up from `path` to the folder holding `.git` (a directory, or a file for worktrees/submodules).
    static func gitRoot(_ path: String) -> String? {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path == home ? nil : url.path
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    // MARK: Window title

    private static func fromTitle(_ title: String, known: [String]) -> String? {
        if title.hasPrefix("/"), let root = gitRoot(title) { return root }
        var parts = [title]
        for sep in [" — ", " – ", " - ", " | ", " · "] { parts = parts.flatMap { $0.components(separatedBy: sep) } }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for part in parts where part.hasPrefix("/") || part.hasPrefix("~") {
            let path = (part as NSString).expandingTildeInPath
            if let root = gitRoot(path) { return root }
        }
        // Prefer the last matching component: editors put the file first and the project last.
        for part in parts.reversed() {
            let name = part.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            if let root = known.first(where: { ($0 as NSString).lastPathComponent == name }) { return root }
        }
        return nil
    }

    // MARK: Processes

    struct Proc {
        let pid: pid_t
        let pgid: pid_t
        let tpgid: pid_t
        let tty: dev_t?
    }

    private static func descendants(of root: pid_t) -> [Proc] {
        var out: [Proc] = []
        var queue: [(pid_t, Int)] = [(root, 0)]
        while !queue.isEmpty, out.count < 500 {
            let (pid, depth) = queue.removeFirst()
            for child in children(pid) {
                if let info = bsdInfo(child) {
                    let noTTY = info.e_tdev == UInt32.max || info.e_tdev == 0
                    out.append(Proc(pid: child, pgid: pid_t(info.pbi_pgid), tpgid: pid_t(info.e_tpgid),
                                    tty: noTTY ? nil : dev_t(bitPattern: info.e_tdev)))
                } else {
                    // Root-owned `login` between Terminal and the shell: no info, but children still list.
                    out.append(Proc(pid: child, pgid: 0, tpgid: 0, tty: nil))
                }
                if depth < 6 { queue.append((child, depth + 1)) }
            }
        }
        return out
    }

    private static func fromActiveTTY(_ procs: [Proc]) -> String? {
        let byTTY = Dictionary(grouping: procs.filter { $0.tty != nil }, by: { $0.tty! })
        let ranked = byTTY.keys.compactMap { dev -> (dev_t, Double)? in
            guard let name = devname(dev, S_IFCHR) else { return nil }
            var st = stat()
            guard stat("/dev/" + String(cString: name), &st) == 0 else { return nil }
            let a = Double(st.st_atimespec.tv_sec) + Double(st.st_atimespec.tv_nsec) / 1e9
            let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            return (dev, max(a, m))
        }.sorted { $0.1 > $1.1 }
        for (dev, _) in ranked {
            let list = byTTY[dev] ?? []
            // The foreground job (vim, claude, a dev server) first, then the shell itself.
            let ordered = list.filter { $0.pgid == $0.tpgid && $0.pgid != 0 } + list
            for p in ordered {
                if let dir = cwd(p.pid), let root = gitRoot(dir) { return root }
            }
            // Most recent tab isn't in a repository: that is the answer, don't fall back to older tabs.
            return nil
        }
        return nil
    }

    private static func children(_ pid: pid_t) -> [pid_t] {
        var buf = [pid_t](repeating: 0, count: 512)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return n > 0 ? Array(buf.prefix(Int(n))) : []
    }

    private static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func cwd(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    /// Title of the app's focused window (Accessibility; nil without the permission).
    static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let win = window else { return nil }
        var value: CFTypeRef?
        // Xcode and other document apps expose the file itself.
        if AXUIElementCopyAttributeValue(win as! AXUIElement, kAXDocumentAttribute as CFString, &value) == .success,
           let doc = value as? String, let url = URL(string: doc), url.isFileURL {
            return url.path
        }
        guard AXUIElementCopyAttributeValue(win as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
