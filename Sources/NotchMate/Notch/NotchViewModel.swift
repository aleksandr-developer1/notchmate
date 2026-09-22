import AppKit
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable {
    case assistant, ai, home, health, jira, git, notes, shelf, clipboard, focus
    var id: String { rawValue }

    /// Pages that are actually available (Git and Health can be turned off in the settings).
    @MainActor var isAvailable: Bool {
        switch self {
        case .git: return Settings.shared.gitEnabled
        case .health: return Settings.shared.garminEnabled || Settings.shared.appleHealthEnabled
        default: return true
        }
    }

    var group: NotchGroup {
        switch self {
        case .assistant, .ai: return .assistant
        case .home: return .home
        case .health: return .health
        case .jira, .git, .focus: return .work
        case .notes: return .notes
        case .shelf, .clipboard: return .shelf
        }
    }

    var icon: String {
        switch self {
        case .assistant: return "face.smiling.inverse"
        case .ai: return "sparkles"
        case .home: return "music.note"
        case .health: return "heart.fill"
        case .jira: return "briefcase.fill"
        case .git: return "arrow.triangle.branch"
        case .notes: return "text.book.closed.fill"
        case .shelf: return "tray.full.fill"
        case .clipboard: return "doc.on.clipboard.fill"
        case .focus: return "timer"
        }
    }

    var title: String {
        switch self {
        case .assistant: return String(localized: "Помощник")
        case .ai: return String(localized: "Чат ИИ")
        case .home: return String(localized: "Музыка")
        case .health: return String(localized: "Здоровье")
        case .jira: return "Jira"
        case .git: return "Git"
        case .notes: return String(localized: "Заметки")
        case .shelf: return String(localized: "Полка")
        case .clipboard: return String(localized: "Буфер")
        case .focus: return String(localized: "Фокус")
        }
    }

    var contentHeight: CGFloat {
        switch self {
        case .assistant: return 196
        case .ai: return 340
        case .home: return 176
        case .health: return 250
        case .jira: return 236
        case .git: return 236
        case .notes: return 340
        case .shelf: return 150
        case .clipboard: return 300
        case .focus: return 176
        }
    }
}

/// A button in the tab bar. Related pages share one button and switch inside it.
enum NotchGroup: String, CaseIterable, Identifiable {
    case assistant, home, health, work, notes, shelf
    var id: String { rawValue }

    /// Groups shown in the bar: those with at least one available page.
    @MainActor static var visible: [NotchGroup] { allCases.filter { !$0.pages.isEmpty } }

    /// Available pages in this group, in switcher order.
    @MainActor var pages: [NotchTab] { NotchTab.allCases.filter { $0.group == self && $0.isAvailable } }

    var icon: String {
        switch self {
        case .assistant: return "face.smiling.inverse"
        case .home: return "music.note"
        case .health: return "heart.fill"
        case .work: return "briefcase.fill"
        case .notes: return "text.book.closed.fill"
        case .shelf: return "tray.full.fill"
        }
    }

    var title: String {
        switch self {
        case .assistant: return String(localized: "Помощник")
        case .home: return String(localized: "Музыка")
        case .health: return String(localized: "Здоровье")
        case .work: return String(localized: "Работа")
        case .notes: return String(localized: "Заметки")
        case .shelf: return String(localized: "Полка")
        }
    }
}

enum OpenReason { case hover, click, hotkey, drag }

enum NotchHUD: Equatable {
    case track(title: String, artist: String)
    case charging(level: Int)
    case timerDone
    case message(icon: String, text: String)
    case speech(String)
}

@MainActor
final class NotchViewModel: ObservableObject {
    @Published private(set) var isOpen = false
    @Published var tab: NotchTab = .assistant {
        didSet { lastPage[tab.group] = tab }
    }
    static let faceHeight: CGFloat = 32
    @Published private(set) var hud: NotchHUD?
    @Published var isTyping = false
    @Published var isDropTargeted = false

    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var hasPhysicalNotch = true

    private(set) var openReason: OpenReason = .hover
    /// Set once the pointer has visited the opened panel (hotkey-open shouldn't close on stray moves).
    var pointerVisited = false

    private var hudWorkItem: DispatchWorkItem?
    let env: AppEnvironment

    init(env: AppEnvironment) {
        self.env = env
    }

    /// Concave top "ears" of the collapsed shape; they sit on the menu bar, outside the visible body.
    static let collapsedEar: CGFloat = 7

    /// Collapsed island width including the ears. The body under the ears matches the camera cutout by default,
    /// or the user's value (never narrower than a real notch).
    var baseWidth: CGFloat {
        let custom = CGFloat(Settings.shared.collapsedWidth)
        let body = custom > 0 ? (hasPhysicalNotch ? max(custom, notchSize.width) : custom) : notchSize.width
        return body + 2 * Self.collapsedEar
    }

    /// Width the wings must leave free in the middle: the camera on notched Macs, the island itself otherwise.
    var cutoutWidth: CGFloat { hasPhysicalNotch ? notchSize.width : baseWidth - 2 * Self.collapsedEar }

    var expandedWidth: CGFloat { max(CGFloat(Settings.shared.expandedWidth), notchSize.width + 420) }

    /// "Now" strip above the tab: shown whenever something runs (music, agents, timers).
    /// Music doesn't count on the home tab — the player is already there.
    var showsNowStrip: Bool {
        if env.calls.stage != .idle { return tab != .assistant }
        return stripShowsMusic || !env.agents.groups.isEmpty || env.focus.isActive || env.jira.isTracking
    }

    var stripShowsMusic: Bool { musicActive && tab != .home }

    static let nowStripHeight: CGFloat = 34
    /// Page switcher above grouped content (Jira / Git / Focus and so on).
    static let pageSwitcherHeight: CGFloat = 30

    /// Whether the current group has more than one page and shows the switcher.
    var showsPageSwitcher: Bool { tab.group.pages.count > 1 }

    var openSize: CGSize {
        CGSize(width: expandedWidth, height: notchSize.height + tab.contentHeight + 14 + (showsPageSwitcher ? Self.pageSwitcherHeight : 0) + (showsNowStrip ? Self.nowStripHeight : 0))
    }

    /// Whether the collapsed notch shows a live activity (wings).
    var liveActivity: LiveActivity? {
        if let work = workActivity { return work }
        if musicActive { return .music }
        return nil
    }

    /// Left side: music whenever it plays.
    var musicActive: Bool {
        Settings.shared.showMusicActivity && (env.nowPlaying.track?.isPlaying ?? false)
    }

    /// Right side: the most important work item.
    var workActivity: LiveActivity? {
        if env.calls.stage != .idle { return .call }
        if env.focus.isActive || env.focus.phase == .finished { return .focus }
        if env.jira.isTracking { return .jira }
        if let e = env.calendar.next, Settings.shared.calendarEnabled, e.start.timeIntervalSinceNow <= 10 * 60, !e.isNow || e.start.timeIntervalSinceNow > -120 { return .meeting }
        if !env.agents.groups.isEmpty { return .agent }
        return nil
    }

    enum LiveActivity { case music, focus, jira, meeting, agent, call }

    var showsFace: Bool { Settings.shared.showFace }

    /// Activity data sits next to the face instead of widening the notch.
    var activityBesideFace: Bool { showsFace && Settings.shared.activityLayout == .besideFace }

    var wingWidth: CGFloat {
        guard !activityBesideFace else { return 0 }
        let hasBadge = env.companion.badge != nil
        if liveActivity == nil && hud == nil && !hasBadge { return 0 }
        switch workActivity {
        case .jira?, .meeting?: return 84
        case .focus?, .agent?, .call?: return 70
        default: return notchSize.height + 16
        }
    }

    // MARK: Docked face

    /// A window of another app sits right under the face (set by the window controller).
    @Published var faceCovered = false

    /// Face moved to the left of the cutout, activity to the right — nothing hangs below the menu bar.
    var isDocked: Bool { showsFace && faceCovered && Settings.shared.dockFaceWhenCovered }

    /// Face pod on the left: a bit wider than the face.
    static var dockFaceWidth: CGFloat { FaceAnimations.crop.width * 0.5 + 14 }

    /// Activity strip on the right (both wings together).
    var dockActivityWidth: CGFloat {
        let hasBadge = env.companion.badge != nil
        if liveActivity == nil && hud == nil && !hasBadge { return 0 }
        switch workActivity {
        case .jira?, .meeting?: return 96
        case .focus?, .agent?, .call?: return 78
        default: return musicActive ? 66 : 36
        }
    }

    /// Docked island is asymmetric; shifting it keeps the cutout in the middle of the camera.
    var closedOffsetX: CGFloat { isDocked && !isOpen ? (dockActivityWidth - Self.dockFaceWidth) / 2 : 0 }

    var closedSize: CGSize {
        var w = baseWidth + wingWidth * 2
        var h = notchSize.height + (showsFace ? Self.faceHeight : 0)
        if isDocked {
            w = cutoutWidth + 2 * Self.collapsedEar + Self.dockFaceWidth + dockActivityWidth
            h = notchSize.height
        }
        if env.ai.isResponding {
            w = max(w, cutoutWidth + 170)
            h += 38
        }
        if env.breathing.isActive {
            w = max(w, cutoutWidth + 190)
            h += 58
        }
        let grow = !activityBesideFace && !isDocked
        if let hud {
            switch hud {
            case .track: if grow { w = max(w, cutoutWidth + 180) }; h += 44
            case .charging: if grow { w = max(w, cutoutWidth + 2 * 64) }
            case .timerDone: if grow { w = max(w, cutoutWidth + 160) }; h += 36
            case .message: if grow { w = max(w, cutoutWidth + 200) }; h += 36
            case .speech: if grow { w = max(w, cutoutWidth + 150) }; h += 30
            }
        }
        return CGSize(width: w, height: h)
    }

    var currentSize: CGSize { isOpen ? openSize : closedSize }

    // MARK: Actions

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let closeSpring = Animation.spring(response: 0.36, dampingFraction: 0.95)

    func open(tab: NotchTab? = nil, reason: OpenReason) {
        if let tab { self.tab = tab }
        guard !isOpen else {
            if reason == .hotkey { onRequestKey?(true) }
            return
        }
        openReason = reason
        pointerVisited = reason == .hover || reason == .click
        dismissHUD()
        if Settings.shared.haptics, reason == .hover || reason == .drag {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        withAnimation(Self.spring) { isOpen = true }
        env.obsidian.refresh()
        onRequestKey?(reason == .hotkey)
    }

    func close() {
        guard isOpen else { return }
        isTyping = false
        withAnimation(Self.closeSpring) { isOpen = false }
        onClose?()
    }

    func select(_ tab: NotchTab) {
        withAnimation(Self.spring) { self.tab = tab }
    }

    /// Last page opened in each group, so the bar button returns to it.
    private var lastPage: [NotchGroup: NotchTab] = [:]

    func select(_ group: NotchGroup) {
        let pages = group.pages
        guard !pages.isEmpty else { return }
        if let last = lastPage[group], pages.contains(last) { select(last) } else { select(pages[0]) }
    }

    /// Hooks wired by the window controller.
    var onRequestKey: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private var hudQueue: [(NotchHUD, TimeInterval)] = []

    func showHUD(_ hud: NotchHUD, duration: TimeInterval = 3) {
        guard !isOpen else { return }
        // Speech banners queue up instead of overwriting each other (e.g. Claude and Codex finishing together).
        if case .speech = hud, case .speech? = self.hud {
            if hudQueue.count < 5 { hudQueue.append((hud, duration)) }
            return
        }
        hudWorkItem?.cancel()
        withAnimation(Self.spring) { self.hud = hud }
        let item = DispatchWorkItem { [weak self] in self?.dismissHUD() }
        hudWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func dismissHUD() {
        hudWorkItem?.cancel()
        guard hud != nil else { return }
        withAnimation(Self.closeSpring) { hud = nil }
        if !hudQueue.isEmpty {
            let (next, duration) = hudQueue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.showHUD(next, duration: duration) }
        }
    }

}
