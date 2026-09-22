import AppKit
import AVFoundation
import CoreGraphics
import EventKit
import Speech
import SwiftUI

/// Every macOS permission NotchMate can ask for, in one place: what it is for,
/// how to check it, how to ask, and which System Settings page to open when
/// macOS refuses to ask again (a permission denied once is never re-prompted).
enum Permission: String, CaseIterable, Identifiable {
    case microphone, screenRecording, speech, calendar, reminders, accessibility, automation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return String(localized: "Микрофон")
        case .screenRecording: return String(localized: "Запись экрана и звука")
        case .speech: return String(localized: "Распознавание речи")
        case .calendar: return String(localized: "Календарь")
        case .reminders: return String(localized: "Напоминания")
        case .accessibility: return String(localized: "Универсальный доступ")
        case .automation: return String(localized: "Управление браузером")
        }
    }

    var icon: String {
        switch self {
        case .microphone: return "mic.fill"
        case .screenRecording: return "rectangle.inset.filled.badge.record"
        case .speech: return "waveform"
        case .calendar: return "calendar"
        case .reminders: return "checklist"
        case .accessibility: return "accessibility"
        case .automation: return "safari"
        }
    }

    var tint: Color {
        switch self {
        case .microphone: return .red
        case .screenRecording: return .purple
        case .speech: return .blue
        case .calendar: return .orange
        case .reminders: return .yellow
        case .accessibility: return .teal
        case .automation: return .indigo
        }
    }

    /// One line: what stops working without it.
    var why: String {
        switch self {
        case .microphone: return String(localized: "Записать ваш голос на созвоне и понять, что разговор вообще идёт.")
        case .screenRecording: return String(localized: "Записать голоса собеседников — звук Zoom, Телемоста или браузера. Экран не снимается и никуда не отправляется.")
        case .speech: return String(localized: "Расшифровать запись созвона встроенным движком macOS, когда whisper не установлен.")
        case .calendar: return String(localized: "Показывать ближайшую встречу в вырезе, напоминать о ней и понимать, что идёт созвон.")
        case .reminders: return String(localized: "Показывать дела из «Напоминаний» на шкале дня и отмечать их выполненными.")
        case .accessibility: return String(localized: "Замечать баннеры уведомлений и новые сообщения, чтобы помощник на них реагировал.")
        case .automation: return String(localized: "Видеть адрес открытой вкладки: созвон в браузере и отвлекающие сайты во время фокуса.")
        }
    }

    /// Whether the feature is even switched on — a permission nobody needs isn't nagged about.
    @MainActor var isNeeded: Bool {
        let s = Settings.shared
        switch self {
        case .microphone, .screenRecording: return s.callsAutoRecord || s.reactCamera
        case .speech: return s.callsAutoRecord
        case .calendar: return s.calendarEnabled
        case .reminders: return s.remindersEnabled
        case .accessibility: return s.reactNotifications || s.reactMessages
        case .automation: return s.distractionBrowsers || s.callsAutoRecord
        }
    }

    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .speech: anchor = "Privacy_SpeechRecognition"
        case .calendar: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .automation: anchor = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

enum PermissionState: Equatable {
    case granted, denied, notDetermined, unknown

    var title: String {
        switch self {
        case .granted: return String(localized: "разрешено")
        case .denied: return String(localized: "запрещено")
        case .notDetermined: return String(localized: "не запрашивалось")
        case .unknown: return String(localized: "неизвестно")
        }
    }

    var color: Color {
        switch self {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined, .unknown: return .secondary
        }
    }
}

@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    @Published private(set) var states: [Permission: PermissionState] = [:]
    private var poll: Timer?

    private init() { refresh() }

    func state(_ p: Permission) -> PermissionState { states[p] ?? .unknown }

    /// Permissions the user needs but hasn't granted, for the features they turned on.
    var missing: [Permission] { Permission.allCases.filter { $0.isNeeded && state($0) != .granted } }

    func refresh() {
        for p in Permission.allCases { states[p] = Self.read(p) }
    }

    /// Keep the window honest while the user toggles switches in System Settings.
    func startWatching() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        poll?.invalidate()
        poll = nil
    }

    private static func read(_ p: Permission) -> PermissionState {
        switch p {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .calendar:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess, .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .reminders:
            switch EKEventStore.authorizationStatus(for: .reminder) {
            case .fullAccess, .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .automation:
            return automationState()
        }
    }

    /// Ask macOS itself whether we may script a running browser — without showing a prompt.
    private static func automationState() -> PermissionState {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter(BrowserTabs.isBrowser)
        guard let target = running.first else { return .unknown }
        var descriptor = AEAddressDesc()
        guard let data = target.data(using: .utf8) else { return .unknown }
        let created: OSErr = data.withUnsafeBytes { raw in
            AECreateDesc(typeApplicationBundleID, raw.baseAddress, raw.count, &descriptor)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&descriptor) }
        switch AEDeterminePermissionToAutomateTarget(&descriptor, typeWildCard, typeWildCard, false) {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .unknown
        default: return .notDetermined
        }
    }

    /// Ask the system politely first; if it won't ask again, open the exact page.
    func request(_ p: Permission) async {
        switch p {
        case .microphone:
            if state(p) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else { open(p) }
        case .screenRecording:
            // There is no "not determined" here — the call prompts once, then silently fails.
            if !CGRequestScreenCaptureAccess() { open(p) }
        case .speech:
            if state(p) == .notDetermined {
                _ = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                    SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
                }
            } else { open(p) }
        case .calendar:
            if state(p) == .notDetermined {
                await AppEnvironment.shared.calendar.requestAccess()
            } else { open(p) }
        case .reminders:
            if state(p) == .notDetermined {
                await AppEnvironment.shared.reminders.requestAccess()
            } else { open(p) }
        case .accessibility:
            // macOS never shows a real dialog for this one — the list is the only way.
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            open(p)
        case .automation:
            // Scripting any browser triggers the one-time dialog.
            if let id = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).first(where: BrowserTabs.isBrowser) {
                _ = BrowserTabs.activeURL(bundleID: id)
                refresh()
                if state(p) != .granted { open(p) }
            } else {
                open(p)
            }
        }
        refresh()
    }

    func open(_ p: Permission) {
        if let url = p.settingsURL { NSWorkspace.shared.open(url) }
    }
}
