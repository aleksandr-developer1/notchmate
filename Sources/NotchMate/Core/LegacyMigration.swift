import Foundation

/// One-time move from the app's former name, Shtorka: settings, the Application Support
/// folder, and the Claude Code / Codex hooks and MCP server that pointed at the old app.
enum LegacyMigration {
    private static let oldBundleID = "com.aleksandrkezikov.shtorka"
    private static let oldFolder = "Shtorka"
    private static let newFolder = "NotchMate"
    private static let pendingKey = "legacyMigrationPending"

    /// Settings and data on disk. Runs before anything reads `Settings` or Application Support.
    static func migrateStorage() {
        let defaults = UserDefaults.standard
        let newID = Bundle.main.bundleIdentifier ?? "com.aleksandrkezikov.notchmate"
        if defaults.persistentDomain(forName: newID)?.isEmpty ?? true,
           var old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty {
            // The Health Auto Export folder in iCloud was a default, not a stored value, and it is
            // written by the iPhone — keep reading from where the export already goes.
            if old["appleHealthFolder"] == nil {
                old["appleHealthFolder"] = "~/Library/Mobile Documents/com~apple~CloudDocs/\(oldFolder)/Health"
            }
            old[pendingKey] = true
            defaults.setPersistentDomain(old, forName: newID)
        }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let from = support.appendingPathComponent(oldFolder), to = support.appendingPathComponent(newFolder)
        if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
            do { try fm.moveItem(at: from, to: to) } catch { NSLog("NotchMate: cannot move \(from.path): \(error)") }
        }
    }

    /// True once, on the first launch after the rename.
    static var isPending: Bool { UserDefaults.standard.bool(forKey: pendingKey) }

    /// Re-points hooks and the MCP server that the user had installed for the old app.
    @MainActor
    static func migrateAgentIntegrations(_ agents: AgentMonitor, codex: CodexAppServer) {
        guard isPending else { return }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        agents.refreshInstallState()
        // Our hooks are found by their "--event …" marker, so reinstalling replaces the old app path.
        if agents.claudeHooksInstalled { try? agents.setClaudeHooks(true) }
        if agents.codexHooksInstalled {
            try? agents.setCodexHooks(true)
            Task { _ = try? await codex.trustNotchMateHooks() }
        }
        Task { await agents.replaceLegacyMCP(oldName: oldFolder.lowercased()) }
    }
}
