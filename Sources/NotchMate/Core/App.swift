import AppKit
import SwiftUI

@main
enum NotchMateMain {
    static func main() {
        HelperModes.runIfNeeded()
        LegacyMigration.migrateStorage()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var notchController: NotchWindowController!
    private var copilotPanel: MeetingCopilotPanelController!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let hotKeys = HotKeyCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = AppEnvironment.shared
        env.start()

        notchController = NotchWindowController(env: env)
        notchController.onOpenSettings = { [weak self] in self?.openSettings() }
        copilotPanel = MeetingCopilotPanelController(env: env)

        setupStatusItem()
        setupHotKeys()
        // First run: walk through exactly what the enabled features need. After the rename from
        // Shtorka macOS treats this as a new app, so the permissions have to be granted again.
        if LegacyMigration.isPending { PermissionsWindow.show(onlyMissing: true) } else { PermissionsWindow.showIfFirstLaunch() }
        LegacyMigration.migrateAgentIntegrations(env.agents, codex: env.ai.codex)
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.notchmate.showPermissions"), object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { PermissionsWindow.show(onlyMissing: false) }
        }
        // `NotchMate --meeting [hint|close]` — same as ⌃⌥H, for scripts and shortcuts.
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.notchmate.meetingAssistant"), object: nil, queue: .main
        ) { note in
            let command = note.object as? String ?? ""
            MainActor.assumeIsolated {
                let copilot = AppEnvironment.shared.copilot
                switch command {
                case "close": copilot.close()
                case "hint": copilot.isActive ? copilot.hintNow() : copilot.activate()
                default: copilot.toggleOrHint()
                }
            }
        }
        env.ai.onAssistantError = { [weak self] message in
            if let self, !self.notchController.viewModel.isOpen {
                self.notchController.viewModel.showHUD(.message(icon: "exclamationmark.triangle.fill", text: String(localized: "Ошибка ответа")), duration: 4)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .notchMateOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }
        NotificationCenter.default.addObserver(
            forName: .notchMateSettingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setupStatusItem()
                self?.setupHotKeys()
            }
        }

        if !Settings.shared.didOnboard {
            Settings.shared.didOnboard = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.notchController.viewModel.open(tab: .assistant, reason: .hotkey)
            }
        }
    }

    // MARK: Status item

    private func setupStatusItem() {
        guard Settings.shared.showMenuBarIcon else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        }
        let image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchMate")
        image?.isTemplate = true
        statusItem?.button?.image = image

        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Открыть панель"), action: #selector(toggleNotch), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Быстрая заметка"), action: #selector(quickCapture), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Чат ИИ"), action: #selector(openAIChat), keyEquivalent: "")
        menu.addItem(withTitle: String(localized: "Помощник на встрече"), action: #selector(meetingAssistant), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Настройки…"), action: #selector(openSettingsAction), keyEquivalent: ",")
        let perms = NSMenuItem(title: String(localized: "Разрешения…"), action: #selector(openPermissions), keyEquivalent: "")
        if !PermissionCenter.shared.missing.isEmpty {
            perms.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        }
        menu.addItem(perms)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Выйти из NotchMate"), action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    private func setupHotKeys() {
        hotKeys.unregisterAll()
        let s = Settings.shared
        if s.hotKeyToggleEnabled {
            hotKeys.register(keyCode: HotKeyCenter.kVK_ANSI_N, modifiers: [.control, .option]) { [weak self] in
                self?.toggleNotch()
            }
        }
        if s.hotKeyMeetingEnabled {
            hotKeys.register(keyCode: HotKeyCenter.kVK_ANSI_H, modifiers: [.control, .option]) { [weak self] in
                self?.meetingAssistant()
            }
        }
        if s.hotKeyCaptureEnabled {
            hotKeys.register(keyCode: HotKeyCenter.kVK_ANSI_M, modifiers: [.control, .option]) { [weak self] in
                self?.quickCapture()
            }
        }
    }

    @objc private func toggleNotch() {
        let vm = notchController.viewModel
        if vm.isOpen { vm.close() } else { vm.open(tab: vm.tab, reason: .hotkey) }
    }

    @objc private func meetingAssistant() {
        AppEnvironment.shared.copilot.toggleOrHint()
    }

    @objc private func quickCapture() {
        notchController.viewModel.open(tab: .notes, reason: .hotkey)
        NotificationCenter.default.post(name: .notchMateFocusCapture, object: nil)
    }

    @objc private func openAIChat() {
        notchController.viewModel.open(tab: .ai, reason: .hotkey)
        NotificationCenter.default.post(name: .notchMateFocusAI, object: nil)
    }

    @objc private func openSettingsAction() { openSettings() }

    @objc private func openPermissions() { PermissionsWindow.show(onlyMissing: false) }

    func openSettings() {
        notchController.viewModel.close()
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView().environmentObject(AppEnvironment.shared))
            let window = NSWindow(contentViewController: hosting)
            window.title = String(localized: "NotchMate — Настройки")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 820, height: 620))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationWillTerminate(_ notification: Notification) {
        // Leaving a capture running keeps the system recording indicator lit.
        AppEnvironment.shared.calls.shutdown()
        AppEnvironment.shared.nowPlaying.stop()
    }
}

extension Notification.Name {
    static let notchMateOpenSettings = Notification.Name("notchmate.openSettings")
    static let notchMateSettingsChanged = Notification.Name("notchmate.settingsChanged")
    static let notchMateFocusCapture = Notification.Name("notchmate.focusCapture")
}
