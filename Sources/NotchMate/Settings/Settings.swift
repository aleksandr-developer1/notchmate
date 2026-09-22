import Foundation
import ServiceManagement

enum CaptureTarget: String, CaseIterable, Identifiable {
    case daily, inbox
    var id: String { rawValue }
    var title: String { self == .daily ? "Ежедневная заметка" : "Файл «Входящие»" }
}

enum ActivityLayout: String, CaseIterable, Identifiable {
    case besideFace, wings
    var id: String { rawValue }
    var title: String { self == .besideFace ? "По бокам от мордочки" : "Слева и справа от камеры" }
}

enum OpenTrigger: String, CaseIterable, Identifiable {
    case hover, click
    var id: String { rawValue }
    var title: String { self == .hover ? "При наведении" : "По клику" }
}

enum NotchGlowMode: String, CaseIterable, Identifiable {
    // TODO: Bring back a live black music effect after a separate visual-design pass.
    case off, artwork

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Выключено"
        case .artwork: return "Цвета обложки"
        }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var openTrigger: OpenTrigger { didSet { d.set(openTrigger.rawValue, forKey: "openTrigger") } }
    @Published var hoverDelay: Double { didSet { d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    @Published var showMusicActivity: Bool { didSet { d.set(showMusicActivity, forKey: "showMusicActivity") } }
    @Published var sneakPeek: Bool { didSet { d.set(sneakPeek, forKey: "sneakPeek") } }
    @Published var chargingHUD: Bool { didSet { d.set(chargingHUD, forKey: "chargingHUD") } }
    @Published var clipboardEnabled: Bool { didSet { d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon"); changed() } }
    @Published var hotKeyToggleEnabled: Bool { didSet { d.set(hotKeyToggleEnabled, forKey: "hotKeyToggle"); changed() } }
    @Published var hotKeyCaptureEnabled: Bool { didSet { d.set(hotKeyCaptureEnabled, forKey: "hotKeyCapture"); changed() } }
    @Published var vaultPath: String { didSet { d.set(vaultPath, forKey: "vaultPath") } }
    @Published var captureTarget: CaptureTarget { didSet { d.set(captureTarget.rawValue, forKey: "captureTarget") } }
    @Published var inboxPath: String { didSet { d.set(inboxPath, forKey: "inboxPath") } }
    @Published var captureTimestamp: Bool { didSet { d.set(captureTimestamp, forKey: "captureTimestamp") } }
    @Published var pinnedNotes: [String] { didSet { d.set(pinnedNotes, forKey: "pinnedNotes") } }
    @Published var pinnedAppleNotes: [String] { didSet { d.set(pinnedAppleNotes, forKey: "pinnedAppleNotes") } }
    @Published var notesSource: NotesSource { didSet { d.set(notesSource.rawValue, forKey: "notesSource") } }
    @Published var preferredPlayer: String { didSet { d.set(preferredPlayer, forKey: "preferredPlayer") } }
    @Published var expandedWidth: Double { didSet { d.set(expandedWidth, forKey: "expandedWidth") } }
    /// Collapsed island width in pt; 0 = match the camera cutout.
    @Published var collapsedWidth: Double { didSet { d.set(collapsedWidth, forKey: "collapsedWidth") } }
    @Published var didOnboard: Bool { didSet { d.set(didOnboard, forKey: "didOnboard") } }
    @Published var jiraURL: String { didSet { d.set(jiraURL, forKey: "jiraURL") } }
    @Published var jiraAuth: JiraAuth { didSet { d.set(jiraAuth.rawValue, forKey: "jiraAuth") } }
    @Published var jiraUser: String { didSet { d.set(jiraUser, forKey: "jiraUser") } }
    @Published var jiraJQL: String { didSet { d.set(jiraJQL, forKey: "jiraJQL") } }
    @Published var jiraActiveKey: String { didSet { d.set(jiraActiveKey, forKey: "jiraActiveKey") } }
    @Published var jiraWorkStatuses: [String] { didSet { d.set(jiraWorkStatuses, forKey: "jiraWorkStatuses") } }
    @Published var jiraWorkHoursOnly: Bool { didSet { d.set(jiraWorkHoursOnly, forKey: "jiraWorkHoursOnly") } }
    @Published var jiraDayStart: Int { didSet { d.set(jiraDayStart, forKey: "jiraDayStart") } }
    @Published var jiraDayEnd: Int { didSet { d.set(jiraDayEnd, forKey: "jiraDayEnd") } }
    @Published var pomoWork: Double { didSet { d.set(pomoWork, forKey: "pomoWork") } }
    @Published var pomoShort: Double { didSet { d.set(pomoShort, forKey: "pomoShort") } }
    @Published var pomoLong: Double { didSet { d.set(pomoLong, forKey: "pomoLong") } }
    @Published var pomoCycle: Int { didSet { d.set(pomoCycle, forKey: "pomoCycle") } }
    @Published var pomoAutoBreak: Bool { didSet { d.set(pomoAutoBreak, forKey: "pomoAutoBreak") } }
    @Published var pomoAutoWork: Bool { didSet { d.set(pomoAutoWork, forKey: "pomoAutoWork") } }
    @Published var dndEnabled: Bool { didSet { d.set(dndEnabled, forKey: "dndEnabled") } }
    @Published var distractionGuard: Bool { didSet { d.set(distractionGuard, forKey: "distractionGuard") } }
    @Published var distractionApps: String { didSet { d.set(distractionApps, forKey: "distractionApps") } }
    @Published var distractionSites: String { didSet { d.set(distractionSites, forKey: "distractionSites") } }
    @Published var distractionBrowsers: Bool { didSet { d.set(distractionBrowsers, forKey: "distractionBrowsers") } }
    @Published var calendarEnabled: Bool { didSet { d.set(calendarEnabled, forKey: "calendarEnabled") } }
    @Published var remindersEnabled: Bool { didSet { d.set(remindersEnabled, forKey: "remindersEnabled"); AppEnvironment.shared.reminders.refresh() } }
    @Published var calendarLeadMinutes: Int { didSet { d.set(calendarLeadMinutes, forKey: "calendarLeadMinutes") } }
    @Published var agentStatusEnabled: Bool { didSet { d.set(agentStatusEnabled, forKey: "agentStatusEnabled") } }
    @Published var agentSound: Bool { didSet { d.set(agentSound, forKey: "agentSound") } }
    @Published var aiToolsEnabled: Bool { didSet { d.set(aiToolsEnabled, forKey: "aiToolsEnabled") } }
    @Published var activityMoods: Bool { didSet { d.set(activityMoods, forKey: "activityMoods") } }
    @Published var idleScenes: Bool { didSet { d.set(idleScenes, forKey: "idleScenes") } }
    @Published var autoDisco: Bool { didSet { d.set(autoDisco, forKey: "autoDisco") } }
    @Published var notchGlowMode: NotchGlowMode { didSet { d.set(notchGlowMode.rawValue, forKey: "notchGlowMode") } }
    @Published var callsAppIDs: [String] { didSet { d.set(callsAppIDs, forKey: "callsAppIDs") } }
    @Published var callsSites: [String] { didSet { d.set(callsSites, forKey: "callsSites") } }
    @Published var callsSeenApps: [String: String] { didSet { d.set(callsSeenApps, forKey: "callsSeenApps") } }
    @Published var callsMinSeconds: Int { didSet { d.set(callsMinSeconds, forKey: "callsMinSeconds") } }
    @Published var callsApps: String { didSet { d.set(callsApps, forKey: "callsApps") } }
    @Published var callsAutoRecord: Bool { didSet { d.set(callsAutoRecord, forKey: "callsAutoRecord") } }
    @Published var callsCaptureMic: Bool { didSet { d.set(callsCaptureMic, forKey: "callsCaptureMic") } }
    @Published var callsKeepAudio: Bool { didSet { d.set(callsKeepAudio, forKey: "callsKeepAudio") } }
    @Published var callsSummaryLocalOnly: Bool { didSet { d.set(callsSummaryLocalOnly, forKey: "callsSummaryLocalOnly") } }
    @Published var callsFolder: String { didSet { d.set(callsFolder, forKey: "callsFolder") } }
    @Published var callsLocale: String { didSet { d.set(callsLocale, forKey: "callsLocale") } }
    @Published var meetingAutoHints: Bool { didSet { d.set(meetingAutoHints, forKey: "meetingAutoHints") } }
    @Published var meetingHideFromCapture: Bool { didSet { d.set(meetingHideFromCapture, forKey: "meetingHideFromCapture") } }
    @Published var meetingRole: String { didSet { d.set(meetingRole, forKey: "meetingRole") } }
    /// "provider|model" of the meeting assistant, "" — the fastest one available.
    @Published var meetingModel: String { didSet { d.set(meetingModel, forKey: "meetingModel") } }
    @Published var meetingHintInterval: Int { didSet { d.set(meetingHintInterval, forKey: "meetingHintInterval") } }
    @Published var hotKeyMeetingEnabled: Bool { didSet { d.set(hotKeyMeetingEnabled, forKey: "hotKeyMeeting"); changed() } }
    @Published var aiProvider: AIProvider { didSet { d.set(aiProvider.rawValue, forKey: "aiProvider") } }
    @Published var aiCodexModel: String { didSet { d.set(aiCodexModel, forKey: "aiCodexModel") } }
    @Published var aiClaudeModel: String { didSet { d.set(aiClaudeModel, forKey: "aiClaudeModel") } }
    @Published var aiOpenAIModel: String { didSet { d.set(aiOpenAIModel, forKey: "aiOpenAIModel") } }
    @Published var aiAnthropicModel: String { didSet { d.set(aiAnthropicModel, forKey: "aiAnthropicModel") } }
    @Published var aiCustomBaseURL: String { didSet { d.set(aiCustomBaseURL, forKey: "aiCustomBaseURL") } }
    @Published var aiCustomModel: String { didSet { d.set(aiCustomModel, forKey: "aiCustomModel") } }
    @Published var reactNotifications: Bool { didSet { d.set(reactNotifications, forKey: "reactNotifications") } }
    @Published var reactMessages: Bool { didSet { d.set(reactMessages, forKey: "reactMessages") } }
    @Published var reactScreenshots: Bool { didSet { d.set(reactScreenshots, forKey: "reactScreenshots"); changed() } }
    @Published var reactCamera: Bool { didSet { d.set(reactCamera, forKey: "reactCamera") } }
    @Published var reactNetwork: Bool { didSet { d.set(reactNetwork, forKey: "reactNetwork") } }
    @Published var reactClipboard: Bool { didSet { d.set(reactClipboard, forKey: "reactClipboard") } }
    @Published var dockFaceWhenCovered: Bool { didSet { d.set(dockFaceWhenCovered, forKey: "dockFaceWhenCovered") } }
    @Published var activityLayout: ActivityLayout { didSet { d.set(activityLayout.rawValue, forKey: "activityLayout") } }
    @Published var showFace: Bool { didSet { d.set(showFace, forKey: "showFace") } }
    @Published var companionName: String { didSet { d.set(companionName, forKey: "companionName") } }
    @Published var faceColor: FacePalette { didSet { d.set(faceColor.rawValue, forKey: "faceColor") } }
    @Published var gitEnabled: Bool { didSet { d.set(gitEnabled, forKey: "gitEnabled") } }
    @Published var gitCIEnabled: Bool { didSet { d.set(gitCIEnabled, forKey: "gitCIEnabled") } }
    @Published var followCursor: Bool { didSet { d.set(followCursor, forKey: "followCursor") } }
    @Published var waterReminder: Bool { didSet { d.set(waterReminder, forKey: "waterReminder") } }
    @Published var waterInterval: Double { didSet { d.set(waterInterval, forKey: "waterInterval") } }
    @Published var stretchReminder: Bool { didSet { d.set(stretchReminder, forKey: "stretchReminder") } }
    @Published var stretchInterval: Double { didSet { d.set(stretchInterval, forKey: "stretchInterval") } }
    @Published var garminEnabled: Bool { didSet { d.set(garminEnabled, forKey: "garminEnabled") } }
    @Published var appleHealthEnabled: Bool { didSet { d.set(appleHealthEnabled, forKey: "appleHealthEnabled") } }
    /// Folder the iPhone exports Apple Health JSON into (iCloud Drive by default).
    @Published var appleHealthFolder: String { didSet { d.set(appleHealthFolder, forKey: "appleHealthFolder") } }
    @Published var healthMoods: Bool { didSet { d.set(healthMoods, forKey: "healthMoods") } }
    @Published var healthStressNudges: Bool { didSet { d.set(healthStressNudges, forKey: "healthStressNudges") } }
    /// Stress level (0–100, Garmin scale) that suggests a breathing break.
    @Published var healthStressThreshold: Double { didSet { d.set(healthStressThreshold, forKey: "healthStressThreshold") } }
    @Published var breathPattern: String { didSet { d.set(breathPattern, forKey: "breathPattern") } }
    @Published var breathMinutes: Double { didSet { d.set(breathMinutes, forKey: "breathMinutes") } }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("NotchMate: launch at login failed: \(error)")
            }
        }
    }

    private init() {
        d.register(defaults: [
            "openTrigger": OpenTrigger.hover.rawValue,
            "hoverDelay": 0.15,
            "haptics": true,
            "gitEnabled": true,
            "gitCIEnabled": true,
            "showMusicActivity": true,
            "sneakPeek": true,
            "chargingHUD": true,
            "clipboardEnabled": true,
            "showMenuBarIcon": true,
            "hotKeyToggle": true,
            "hotKeyCapture": true,
            "vaultPath": "",
            "captureTarget": CaptureTarget.daily.rawValue,
            "inboxPath": "Входящие.md",
            "captureTimestamp": true,
            "pinnedNotes": [String](),
            "pinnedAppleNotes": [String](),
            "notesSource": NotesSource.apple.rawValue,
            "preferredPlayer": "yandex",
            "expandedWidth": 660.0,
            "collapsedWidth": 0.0,
            "didOnboard": false,
            "jiraURL": "",
            "jiraAuth": JiraAuth.token.rawValue,
            "jiraUser": "",
            "jiraJQL": "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC",
            "jiraActiveKey": "",
            "jiraWorkStatuses": [String](),
            "jiraWorkHoursOnly": true,
            "jiraDayStart": 10,
            "jiraDayEnd": 19,
            "showFace": true,
            "activityLayout": ActivityLayout.besideFace.rawValue,
            "dockFaceWhenCovered": true,
            "pomoWork": 25.0,
            "pomoShort": 5.0,
            "pomoLong": 15.0,
            "pomoCycle": 4,
            "pomoAutoBreak": true,
            "pomoAutoWork": false,
            "dndEnabled": true,
            "distractionGuard": true,
            "distractionApps": "Telegram, Steam, Discord, VK, WhatsApp",
            "distractionSites": "youtube.com, reddit.com, vk.com, instagram.com, tiktok.com, twitch.tv, x.com, pikabu.ru, dzen.ru",
            "distractionBrowsers": true,
            "calendarEnabled": true,
            "calendarLeadMinutes": 5,
            "remindersEnabled": true,
            "agentStatusEnabled": true,
            "agentSound": true,
            "aiToolsEnabled": true,
            "activityMoods": true,
            "idleScenes": true,
            "autoDisco": true,
            "notchGlowMode": NotchGlowMode.artwork.rawValue,
            "callsAppIDs": [String](),
            "callsSites": ["meet.google.com", "telemost.yandex.ru", "zoom.us", "teams.microsoft.com", "teams.live.com", "jazz.sber.ru", "salutejazz.ru", "ktalk.ru", "mts-link.ru", "webex.com", "whereby.com", "app.slack.com", "discord.com"],
            "callsSeenApps": [String: String](),
            "callsMinSeconds": 30,
            "callsApps": "zoom, telemost, yandex, teams, meet, webex, discord, jazz, ktalk, mts-link, facetime, толк, slack, skype, telegram, whereby, chime",
            "callsAutoRecord": true,
            "callsCaptureMic": true,
            "callsKeepAudio": false,
            "callsSummaryLocalOnly": true,
            "callsFolder": "Созвоны",
            "callsLocale": "ru-RU",
            "meetingAutoHints": true,
            "meetingModel": "",
            "meetingRole": "разработчик и автор обсуждаемого проекта, хорошо знает код, архитектуру и предметную область",
            "meetingHideFromCapture": true,
            "meetingHintInterval": 12,
            "hotKeyMeeting": true,
            "aiProvider": AIProvider.chatgpt.rawValue,
            "aiCodexModel": "",
            "aiClaudeModel": "sonnet",
            "aiOpenAIModel": "gpt-5.5",
            "aiAnthropicModel": "claude-opus-5",
            "aiCustomBaseURL": "",
            "aiCustomModel": "",
            "reactNotifications": false,
            "reactMessages": false,
            "reactScreenshots": false,
            "reactCamera": true,
            "reactNetwork": true,
            "reactClipboard": true,
            "companionName": "Пикси",
            "faceColor": FacePalette.oled.rawValue,
            "followCursor": true,
            "waterReminder": true,
            "waterInterval": 60.0,
            "stretchReminder": true,
            "stretchInterval": 90.0,
            "garminEnabled": false,
            "appleHealthEnabled": false,
            "appleHealthFolder": "~/Library/Mobile Documents/com~apple~CloudDocs/NotchMate/Health",
            "healthMoods": true,
            "healthStressNudges": true,
            "healthStressThreshold": 60.0,
            "breathPattern": "calm",
            "breathMinutes": 2.0,
        ])
        openTrigger = OpenTrigger(rawValue: d.string(forKey: "openTrigger") ?? "") ?? .hover
        hoverDelay = d.double(forKey: "hoverDelay")
        haptics = d.bool(forKey: "haptics")
        showMusicActivity = d.bool(forKey: "showMusicActivity")
        sneakPeek = d.bool(forKey: "sneakPeek")
        chargingHUD = d.bool(forKey: "chargingHUD")
        clipboardEnabled = d.bool(forKey: "clipboardEnabled")
        showMenuBarIcon = d.bool(forKey: "showMenuBarIcon")
        hotKeyToggleEnabled = d.bool(forKey: "hotKeyToggle")
        hotKeyCaptureEnabled = d.bool(forKey: "hotKeyCapture")
        vaultPath = d.string(forKey: "vaultPath") ?? ""
        captureTarget = CaptureTarget(rawValue: d.string(forKey: "captureTarget") ?? "") ?? .daily
        inboxPath = d.string(forKey: "inboxPath") ?? "Входящие.md"
        captureTimestamp = d.bool(forKey: "captureTimestamp")
        pinnedNotes = d.stringArray(forKey: "pinnedNotes") ?? []
        pinnedAppleNotes = d.stringArray(forKey: "pinnedAppleNotes") ?? []
        notesSource = NotesSource(rawValue: d.string(forKey: "notesSource") ?? "") ?? .apple
        preferredPlayer = d.string(forKey: "preferredPlayer") ?? "yandex"
        expandedWidth = d.double(forKey: "expandedWidth")
        collapsedWidth = d.double(forKey: "collapsedWidth")
        didOnboard = d.bool(forKey: "didOnboard")
        jiraURL = d.string(forKey: "jiraURL") ?? ""
        jiraAuth = JiraAuth(rawValue: d.string(forKey: "jiraAuth") ?? "") ?? .token
        jiraUser = d.string(forKey: "jiraUser") ?? ""
        jiraJQL = d.string(forKey: "jiraJQL") ?? ""
        jiraActiveKey = d.string(forKey: "jiraActiveKey") ?? ""
        jiraWorkStatuses = d.stringArray(forKey: "jiraWorkStatuses") ?? []
        jiraWorkHoursOnly = d.bool(forKey: "jiraWorkHoursOnly")
        jiraDayStart = d.integer(forKey: "jiraDayStart")
        jiraDayEnd = d.integer(forKey: "jiraDayEnd")
        showFace = d.bool(forKey: "showFace")
        pomoWork = d.double(forKey: "pomoWork")
        pomoShort = d.double(forKey: "pomoShort")
        pomoLong = d.double(forKey: "pomoLong")
        pomoCycle = d.integer(forKey: "pomoCycle")
        pomoAutoBreak = d.bool(forKey: "pomoAutoBreak")
        pomoAutoWork = d.bool(forKey: "pomoAutoWork")
        dndEnabled = d.bool(forKey: "dndEnabled")
        distractionGuard = d.bool(forKey: "distractionGuard")
        distractionApps = d.string(forKey: "distractionApps") ?? "Telegram, Steam, Discord, VK, WhatsApp"
        distractionSites = d.string(forKey: "distractionSites") ?? "youtube.com, reddit.com, vk.com, instagram.com, tiktok.com, twitch.tv, x.com, pikabu.ru, dzen.ru"
        distractionBrowsers = d.bool(forKey: "distractionBrowsers")
        calendarEnabled = d.bool(forKey: "calendarEnabled")
        calendarLeadMinutes = d.integer(forKey: "calendarLeadMinutes")
        remindersEnabled = d.bool(forKey: "remindersEnabled")
        agentStatusEnabled = d.bool(forKey: "agentStatusEnabled")
        agentSound = d.bool(forKey: "agentSound")
        aiToolsEnabled = d.bool(forKey: "aiToolsEnabled")
        activityMoods = d.bool(forKey: "activityMoods")
        idleScenes = d.bool(forKey: "idleScenes")
        autoDisco = d.bool(forKey: "autoDisco")
        let savedGlowMode = d.string(forKey: "notchGlowMode") ?? ""
        // The removed experimental live mode should not silently turn into a colored glow.
        notchGlowMode = NotchGlowMode(rawValue: savedGlowMode) ?? .off
        callsAppIDs = d.stringArray(forKey: "callsAppIDs") ?? [String]()
        callsSites = d.stringArray(forKey: "callsSites") ?? ["meet.google.com", "telemost.yandex.ru", "zoom.us", "teams.microsoft.com", "teams.live.com", "jazz.sber.ru", "salutejazz.ru", "ktalk.ru", "mts-link.ru", "webex.com", "whereby.com", "app.slack.com", "discord.com"]
        callsSeenApps = (d.dictionary(forKey: "callsSeenApps") as? [String: String]) ?? [:]
        callsMinSeconds = d.integer(forKey: "callsMinSeconds")
        callsApps = d.string(forKey: "callsApps") ?? "zoom, telemost, yandex, teams, meet, webex, discord, jazz, ktalk, mts-link, facetime, толк, slack, skype, telegram, whereby, chime"
        callsAutoRecord = d.bool(forKey: "callsAutoRecord")
        callsCaptureMic = d.bool(forKey: "callsCaptureMic")
        callsKeepAudio = d.bool(forKey: "callsKeepAudio")
        callsSummaryLocalOnly = d.bool(forKey: "callsSummaryLocalOnly")
        callsFolder = d.string(forKey: "callsFolder") ?? "Созвоны"
        callsLocale = d.string(forKey: "callsLocale") ?? "ru-RU"
        meetingAutoHints = d.bool(forKey: "meetingAutoHints")
        meetingModel = d.string(forKey: "meetingModel") ?? ""
        meetingRole = d.string(forKey: "meetingRole") ?? ""
        meetingHideFromCapture = d.bool(forKey: "meetingHideFromCapture")
        meetingHintInterval = max(8, d.integer(forKey: "meetingHintInterval"))
        hotKeyMeetingEnabled = d.bool(forKey: "hotKeyMeeting")
        aiProvider = AIProvider(rawValue: d.string(forKey: "aiProvider") ?? "") ?? .chatgpt
        aiCodexModel = d.string(forKey: "aiCodexModel") ?? ""
        aiClaudeModel = d.string(forKey: "aiClaudeModel") ?? "sonnet"
        aiOpenAIModel = d.string(forKey: "aiOpenAIModel") ?? "gpt-5.5"
        aiAnthropicModel = d.string(forKey: "aiAnthropicModel") ?? "claude-opus-5"
        aiCustomBaseURL = d.string(forKey: "aiCustomBaseURL") ?? ""
        aiCustomModel = d.string(forKey: "aiCustomModel") ?? ""
        reactNotifications = d.bool(forKey: "reactNotifications")
        reactMessages = d.bool(forKey: "reactMessages")
        reactScreenshots = d.bool(forKey: "reactScreenshots")
        reactCamera = d.bool(forKey: "reactCamera")
        reactNetwork = d.bool(forKey: "reactNetwork")
        reactClipboard = d.bool(forKey: "reactClipboard")
        activityLayout = ActivityLayout(rawValue: d.string(forKey: "activityLayout") ?? "") ?? .besideFace
        dockFaceWhenCovered = d.bool(forKey: "dockFaceWhenCovered")
        companionName = d.string(forKey: "companionName") ?? "Пикси"
        faceColor = FacePalette(rawValue: d.string(forKey: "faceColor") ?? "") ?? .oled
        followCursor = d.bool(forKey: "followCursor")
        gitEnabled = d.bool(forKey: "gitEnabled")
        gitCIEnabled = d.bool(forKey: "gitCIEnabled")
        waterReminder = d.bool(forKey: "waterReminder")
        waterInterval = d.double(forKey: "waterInterval")
        stretchReminder = d.bool(forKey: "stretchReminder")
        stretchInterval = d.double(forKey: "stretchInterval")
        garminEnabled = d.bool(forKey: "garminEnabled")
        appleHealthEnabled = d.bool(forKey: "appleHealthEnabled")
        appleHealthFolder = d.string(forKey: "appleHealthFolder") ?? ""
        healthMoods = d.bool(forKey: "healthMoods")
        healthStressNudges = d.bool(forKey: "healthStressNudges")
        healthStressThreshold = d.double(forKey: "healthStressThreshold")
        breathPattern = d.string(forKey: "breathPattern") ?? "calm"
        breathMinutes = d.double(forKey: "breathMinutes")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func changed() {
        NotificationCenter.default.post(name: .notchMateSettingsChanged, object: nil)
    }
}
