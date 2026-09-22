import AppKit
import ApplicationServices
import CoreMediaIO
import Network
import SwiftUI

/// Watches the Mac for events the assistant can react to.
/// Permission-free: network, wake/unlock, disks, camera. Opt-in: notifications & message badges
/// (Accessibility), screenshots (reads the screenshot folder).
@MainActor
final class SystemEvents: ObservableObject {
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()

    private weak var env: AppEnvironment?
    private var companion: Companion? { env?.companion }
    private let settings = Settings.shared

    private let pathMonitor = NWPathMonitor()
    private var lastPathSatisfied: Bool?
    private var pollTimer: Timer?
    private var fastTimer: Timer?
    @Published private(set) var cameraActive = false
    private var cameraOn = false
    private var bannerSignature = 0
    private var dockBadges: [String: Int] = [:]
    private var dockPrimed = false
    private var screenshotSource: DispatchSourceFileSystemObject?
    private var screenshotDir: URL?
    private var knownShots: Set<String> = []
    private var lastAwayStart: Date?

    func start(env: AppEnvironment) {
        self.env = env
        watchNetwork()
        watchWorkspace()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.slowPoll() }
        }
        // Accessibility has no reliable notification for new Notification Center banners.
        // Its view tree is comparatively expensive to walk, so don't do it at animation speed.
        fastTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fastPoll() }
        }
        NotificationCenter.default.addObserver(forName: .notchMateSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshScreenshotWatcher() }
        }
        refreshScreenshotWatcher()
    }

    // MARK: Network

    private func watchNetwork() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.networkChanged(ok) }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "notchmate.network"))
    }

    private func networkChanged(_ ok: Bool) {
        defer { lastPathSatisfied = ok }
        guard settings.reactNetwork, let previous = lastPathSatisfied, previous != ok else { return }
        if ok {
            companion?.notify(.happy, badge: .init(symbol: "wifi", image: nil, tint: .green), seconds: 2.5)
        } else {
            companion?.notify(.sad, badge: .init(symbol: "wifi.slash", image: nil, tint: .red), seconds: 4)
        }
    }

    // MARK: Workspace (wake, unlock, disks)

    private func watchWorkspace() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.companion?.react(.startup, for: 8) }
        }
        ws.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.companion?.notify(.surprised, badge: .init(symbol: "externaldrive.fill", image: nil, tint: .white), seconds: 2.5)
            }
        }
        let dist = DistributedNotificationCenter.default()
        dist.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastAwayStart = Date() }
        }
        dist.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let away = self.lastAwayStart.map { Date().timeIntervalSince($0) } ?? 0
                self.companion?.react(away > 600 ? .love : .happy, for: 2.5)
            }
        }
    }

    // MARK: Polling

    private func slowPoll() {
        accessibilityTrusted = AXIsProcessTrusted()
        if settings.reactCamera {
            let on = Self.isCameraRunning()
            if on != cameraOn {
                cameraOn = on
                cameraActive = on
                companion?.inCall = on
                if on { companion?.notify(.surprised, badge: .init(symbol: "video.fill", image: nil, tint: .green), seconds: 1.8) }
            }
        } else if cameraOn {
            cameraOn = false
            cameraActive = false
            companion?.inCall = false
        }
        if settings.reactMessages, accessibilityTrusted { pollDockBadges() }
    }

    private func fastPoll() {
        if settings.reactNotifications, accessibilityTrusted { pollNotificationBanners() }
    }

    // MARK: Camera (CoreMediaIO, no permission needed to ask "is it running")

    static func isCameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == noErr else { return false }
        for id in ids {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(id, &a, 0, nil, s, &s, &running) == noErr, running != 0 { return true }
        }
        return false
    }

    // MARK: Notification banners (Accessibility)

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func pollNotificationBanners() {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var banners: [AXUIElement] = []
        collectBanners(root, depth: 0, into: &banners)
        let signature = banners.count
        if signature > bannerSignature, let newest = banners.last {
            let sender = Self.string(newest, kAXDescriptionAttribute) ?? Self.string(newest, kAXTitleAttribute) ?? ""
            if env?.isDoNotDisturb == true {
                companion?.nudge(.alert, for: 1.5)
            } else {
                companion?.notify(.alert, badge: Self.badge(forSenderText: sender, fallbackSymbol: "bell.fill"))
            }
        }
        bannerSignature = signature
    }

    private func collectBanners(_ el: AXUIElement, depth: Int, into out: inout [AXUIElement]) {
        guard depth < 7, out.count < 20 else { return }
        let subrole = Self.string(el, kAXSubroleAttribute) ?? ""
        if subrole.contains("NotificationCenterBanner") || subrole.contains("NotificationCenterAlert") {
            out.append(el)
            return
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list { collectBanners(child, depth: depth + 1, into: &out) }
    }

    // MARK: Dock badges — new messages (Accessibility)

    private static let messengerHints = ["telegram", "slack", "почта", "mail", "сообщения", "messages", "whatsapp", "discord", "мессенджер", "толк", "teams", "zoom", "vk", "skype"]

    private func pollDockBadges() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &children) == .success,
              let lists = children as? [AXUIElement] else { return }
        var current: [String: (Int, URL?)] = [:]
        for list in lists {
            var items: CFTypeRef?
            guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &items) == .success,
                  let dockItems = items as? [AXUIElement] else { continue }
            for item in dockItems {
                guard let title = Self.string(item, kAXTitleAttribute),
                      let label = Self.string(item, "AXStatusLabel"), !label.isEmpty else { continue }
                let count = Int(label.filter(\.isNumber)) ?? 1
                var urlRef: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &urlRef)
                current[title] = (count, urlRef as? URL)
            }
        }
        if dockPrimed {
            for (title, (count, url)) in current where count > (dockBadges[title] ?? 0) {
                let lower = title.lowercased()
                let isMessenger = Self.messengerHints.contains { lower.contains($0) }
                let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
                companion?.notify(isMessenger ? .message : .alert,
                                  badge: .init(symbol: icon == nil ? "envelope.fill" : nil, image: icon, tint: .white))
                break
            }
        }
        dockBadges = current.mapValues(\.0)
        dockPrimed = true
    }

    // MARK: Screenshots

    private func refreshScreenshotWatcher() {
        screenshotSource?.cancel()
        screenshotSource = nil
        guard settings.reactScreenshots else { return }
        let custom = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
        let dir = URL(fileURLWithPath: (custom as NSString?)?.expandingTildeInPath ?? (NSHomeDirectory() + "/Desktop"))
        screenshotDir = dir
        knownShots = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.screenshotFolderChanged() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        screenshotSource = src
    }

    private func screenshotFolderChanged() {
        guard let dir = screenshotDir else { return }
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let added = now.subtracting(knownShots)
        knownShots = now
        let isShot = added.contains { name in
            let l = name.lowercased()
            return !l.hasPrefix(".") && (l.contains("снимок экрана") || l.contains("screenshot") || l.contains("запись экрана") || l.contains("screen recording"))
        }
        if isShot { companion?.notify(.shutter, badge: .init(symbol: "camera.fill", image: nil, tint: .white), seconds: 2.8) }
    }

    // MARK: Helpers

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    /// Finds the sending app's icon by matching a running app name inside the banner text.
    private static func badge(forSenderText text: String, fallbackSymbol: String) -> CompanionBadge {
        let lower = text.lowercased()
        let app = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .first { app in
                guard let name = app.localizedName?.lowercased(), name.count > 2 else { return false }
                return lower.hasPrefix(name) || lower.contains(name + ",")
            }
        if let icon = app?.icon { return CompanionBadge(symbol: nil, image: icon, tint: .white) }
        return CompanionBadge(symbol: fallbackSymbol, image: nil, tint: .yellow)
    }
}
