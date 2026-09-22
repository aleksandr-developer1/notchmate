import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// AppKit pushes windows below the menu bar by default — the notch must stay glued to the top edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The panel is usually not key (hover-open, another app active). Without this the first click only
/// makes the panel key and SwiftUI buttons ignore it — they look "dead" until clicked again.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchWindowController {
    let viewModel: NotchViewModel
    var onOpenSettings: (() -> Void)?

    private let panel: NotchPanel
    private let env: AppEnvironment
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var screen: NSScreen?

    private let panelSize = CGSize(width: 1000, height: 520)

    init(env: AppEnvironment) {
        self.env = env
        viewModel = NotchViewModel(env: env)
        env.notch = viewModel

        panel = NotchPanel(contentRect: .init(origin: .zero, size: panelSize),
                           styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                           backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        // Must come after isFloatingPanel (which resets level to .floating). Above menu bar (24) and status items (25),
        // below pop-up menus (101) so context menus still appear on top.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.animationBehavior = .none

        let root = NotchRootView()
            .environmentObject(viewModel)
            .environmentObject(env)
            .environmentObject(env.settings)
            .environmentObject(env.nowPlaying)
            .environmentObject(env.tempo)
            .environmentObject(env.disco)
            .environmentObject(env.health)
            .environmentObject(env.breathing)
            .environmentObject(env.obsidian)
            .environmentObject(env.shelf)
            .environmentObject(env.clipboard)
            .environmentObject(env.focus)
            .environmentObject(env.battery)
            .environmentObject(env.volume)
            .environmentObject(env.companion)
            .environmentObject(env.jira)
            .environmentObject(env.ai)
            .environmentObject(env.calendar)
            .environmentObject(env.reminders)
            .environmentObject(env.agents)
            .environmentObject(env.distractions)
            .environmentObject(env.attention)
            .environmentObject(env.calls)
            .environmentObject(env.copilot)
            .environmentObject(env.git)
        let hosting = NotchHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        wireViewModel()
        wireInteractivity()
        Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFaceCovered() }
        }
        wireEvents()
        wireServices()
        panel.orderFrontRegardless()
        positionOnScreen()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionOnScreen() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        }
    }

    // MARK: Geometry

    private func positionOnScreen() {
        let target = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return }
        screen = target
        let frame = target.frame

        if target.safeAreaInsets.top > 0,
           let left = target.auxiliaryTopLeftArea, let right = target.auxiliaryTopRightArea {
            viewModel.hasPhysicalNotch = true
            viewModel.notchSize = CGSize(width: frame.width - left.width - right.width,
                                         height: target.safeAreaInsets.top)
        } else {
            // No notch: draw a slim virtual island under the menu bar.
            viewModel.hasPhysicalNotch = false
            let menuBar = frame.maxY - target.visibleFrame.maxY
            viewModel.notchSize = CGSize(width: 200, height: max(menuBar, 24))
        }
        panel.setFrame(NSRect(x: frame.midX - panelSize.width / 2, y: frame.maxY - panelSize.height,
                              width: panelSize.width, height: panelSize.height), display: true)
    }

    /// Visible notch rect in screen coordinates.
    private func contentRect(for size: CGSize, offset: CGFloat = 0) -> NSRect {
        guard let frame = screen?.frame else { return .zero }
        return NSRect(x: frame.midX - size.width / 2 + offset, y: frame.maxY - size.height, width: size.width, height: size.height)
    }

    // MARK: Face over windows

    private var uncoveredChecks = 0

    /// Is a window of another app right under the face? Window bounds need no permission.
    private func checkFaceCovered() {
        guard let frame = screen?.frame else { return }
        let vm = viewModel
        guard Settings.shared.dockFaceWhenCovered, vm.showsFace else {
            if vm.faceCovered { vm.faceCovered = false }
            return
        }
        // Area where the face hangs in normal mode, a little wider.
        let faceWidth = FaceAnimations.crop.width * 0.5 + 16
        let area = NSRect(x: frame.midX - faceWidth / 2, y: frame.maxY - vm.notchSize.height - NotchViewModel.faceHeight,
                          width: faceWidth, height: NotchViewModel.faceHeight)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let cgArea = CGRect(x: area.minX, y: primaryHeight - area.maxY, width: area.width, height: area.height)
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let covered = list.contains { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width > 60, bounds.height > 60 else { return false }
            return bounds.intersects(cgArea)
        }
        // Dock at once; come back only after the area has been free for a moment (no flicker while dragging).
        if covered {
            uncoveredChecks = 0
            if !vm.faceCovered { withAnimation(NotchViewModel.spring) { vm.faceCovered = true } }
        } else if vm.faceCovered {
            uncoveredChecks += 1
            if uncoveredChecks >= 2 { withAnimation(NotchViewModel.spring) { vm.faceCovered = false } }
        }
    }

    // MARK: Wiring

    private func wireViewModel() {
        viewModel.onRequestKey = { [weak self] activate in
            guard let self else { return }
            self.updateMouseInteractivity(at: NSEvent.mouseLocation)
            if activate {
                if NSRunningApplication.current != NSWorkspace.shared.frontmostApplication {
                    self.previousApp = NSWorkspace.shared.frontmostApplication
                }
                NSApp.activate()
                self.panel.makeKeyAndOrderFront(nil)
            }
        }
        viewModel.onClose = { [weak self] in
            guard let self else { return }
            self.openWork?.cancel()
            self.closeWork?.cancel()
            if self.panel.isKeyWindow {
                self.panel.makeFirstResponder(nil)
                if let prev = self.previousApp, !prev.isTerminated {
                    prev.activate()
                } else {
                    NSApp.deactivate()
                }
            }
            self.previousApp = nil
            self.updateMouseInteractivity(at: NSEvent.mouseLocation)
        }
    }

    private func wireInteractivity() {
        // The clickable rect changes with open state, tab height and HUD — not only when the mouse moves.
        // Recompute after the change is applied, otherwise a stale rect leaves buttons unclickable
        // (or blocks clicks on the menu bar under the transparent panel).
        viewModel.$isOpen.map { _ in () }
            .merge(with: viewModel.$tab.map { _ in () }, viewModel.$hud.map { _ in () }, viewModel.$notchSize.map { _ in () },
                   viewModel.$faceCovered.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateMouseInteractivity(at: NSEvent.mouseLocation) }
            .store(in: &cancellables)
    }

    private func wireServices() {
        env.nowPlaying.onTrackChange = { [weak self] track in
            guard let self else { return }
            self.env.companion.bump(\.tracks)
            self.env.companion.nudge(.nod, for: 1.4)
            guard Settings.shared.sneakPeek, track.isPlaying, !self.viewModel.isOpen, !self.env.isDoNotDisturb else { return }
            self.viewModel.showHUD(.track(title: track.title, artist: track.artist), duration: 3.2)
        }
        env.battery.onPlugged = { [weak self] in
            guard let self else { return }
            self.env.companion.react(.excited, for: 2.5)
            guard Settings.shared.chargingHUD, !self.env.isDoNotDisturb else { return }
            self.viewModel.showHUD(.charging(level: self.env.battery.level), duration: 2.6)
        }
        env.focus.onFinish = { [weak self] finished, next in
            guard let self else { return }
            if finished != .work {
                self.env.companion.react(.happy, for: 2.5)
                self.viewModel.showHUD(.timerDone, duration: 5)
                return
            }
            self.env.distractions.resetSession()
            self.env.companion.bump(\.focusMinutes, by: Int(self.env.focus.total / 60))
            self.env.companion.bump(\.pomodoros)
            self.env.companion.react(.excited, for: 4)
            self.viewModel.showHUD(.timerDone, duration: 6)
        }
        env.battery.onLow = { [weak self] in
            self?.env.companion.notify(.sad, badge: .init(symbol: "battery.25percent", image: nil, tint: .red), seconds: 4)
        }
        env.clipboard.onNewItem = { [weak self] in
            guard Settings.shared.reactClipboard else { return }
            self?.env.companion.nudge(.nod, for: 1.4)
        }
        env.jira.onLogged = { [weak self] in
            self?.env.companion.notify(.proud, badge: .init(symbol: "checkmark.circle.fill", image: nil, tint: .green), seconds: 3.3)
        }
        env.jira.onOverrun = { [weak self] issue in
            self?.env.companion.notify(.sad, badge: .init(symbol: "exclamationmark.triangle.fill", image: nil, tint: .orange), seconds: 4)
            self?.viewModel.showHUD(.speech(String(localized: "\(issue.key): эстимейт превышен")), duration: 4)
        }
        env.ai.onRespondingChanged = { [weak self] responding in
            if responding { self?.env.companion.react(.focused, for: 120) } else { self?.env.companion.react(.nod, for: 1.4) }
            if !responding, let self, !self.viewModel.isOpen {
                self.viewModel.showHUD(.message(icon: "checkmark.circle.fill", text: String(localized: "Ответ готов")), duration: 3.2)
            }
        }
        env.distractions.onNudge = { [weak self] source in
            guard let self else { return }
            let target = self.env.jira.activeIssue.map { $0.key } ?? String(localized: "фокусу")
            self.env.companion.notify(.disappointed, badge: .init(symbol: "eye.trianglebadge.exclamationmark", image: nil, tint: .orange), seconds: 4)
            self.viewModel.showHUD(.speech(String(localized: "\(source) подождёт — вернёмся к \(target)?")), duration: 4)
        }
        env.agents.onWaiting = { [weak self] s in
            guard let self else { return }
            self.env.companion.notify(.alert, badge: .init(symbol: s.agent.icon == nil ? s.agent.fallbackSymbol : nil, image: s.agent.icon, tint: s.agent.tint), seconds: 3)
            self.viewModel.showHUD(.speech(String(localized: "\(s.agent.title) ждёт ответа · \(s.project)")), duration: 5)
            if Settings.shared.agentSound { NSSound(named: "Ping")?.play() }
        }
        env.agents.onFinished = { [weak self] s in
            guard let self else { return }
            self.env.attention.agentFinished(s)
            let seconds = Int(Date().timeIntervalSince(s.startedAt))
            self.env.companion.notify(.ready, badge: .init(symbol: s.agent.icon == nil ? s.agent.fallbackSymbol : nil, image: s.agent.icon, tint: s.agent.tint), seconds: 3)
            // Short answers don't need a banner; long runs do (you were waiting for them, so this ignores quiet mode).
            if seconds >= 20 {
                self.viewModel.showHUD(.speech(String(localized: "\(s.agent.title) закончил · \(s.project) · \(FocusTimer.format(TimeInterval(seconds)))")), duration: 5)
                if Settings.shared.agentSound { NSSound(named: "Glass")?.play() }
            }
        }
        env.calendar.onSoon = { [weak self] e in
            guard let self else { return }
            self.env.companion.notify(.alert, badge: .init(symbol: "calendar", image: nil, tint: e.color), seconds: 3)
            self.viewModel.showHUD(.speech(String(localized: "Через \(max(e.minutesUntil, 1)) мин: \(e.title)")), duration: 6)
        }
        env.calendar.onStart = { [weak self] e in
            guard let self, e.meetingURL != nil else { return }
            self.viewModel.showHUD(.speech(String(localized: "Начинается: \(e.title)")), duration: 6)
        }
        NotificationCenter.default.addObserver(forName: .notchMateShowSpeech, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let text = note.object as? String else { return }
                self?.viewModel.showHUD(.speech(text), duration: 5)
            }
        }
        env.calls.onFinished = { [weak self] title, _ in
            guard let self else { return }
            self.env.companion.notify(.proud, badge: .init(symbol: "text.document.fill", image: nil, tint: Theme.obsidian), seconds: 3)
            self.viewModel.showHUD(.speech(String(localized: "Протокол созвона готов: \(title)")), duration: 6)
        }
        env.companion.onSpeak = { [weak self] text in
            self?.viewModel.showHUD(.speech(text), duration: 4)
        }
        // Re-render collapsed state when live activity sources change.
        env.shelf.$items.dropFirst().sink { [weak self] _ in
            self?.env.companion.react(.eating, for: 2.2)
        }.store(in: &cancellables)
        env.nowPlaying.objectWillChange.merge(with: env.focus.objectWillChange, env.settings.objectWillChange, env.jira.objectWillChange, env.companion.objectWillChange, env.ai.objectWillChange, env.agents.objectWillChange, env.calendar.objectWillChange)
            .merge(with: env.health.objectWillChange, env.breathing.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.viewModel.objectWillChange.send() }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: .notchMateCaptureSaved, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                let text = note.object as? String ?? String(localized: "Сохранено")
                self.env.companion.bump(\.notes)
                self.env.companion.react(.happy, for: 2.5)
                if self.viewModel.isOpen && self.viewModel.openReason == .hotkey && self.viewModel.tab == .notes && !self.viewModel.pointerVisited {
                    self.viewModel.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.viewModel.showHUD(.message(icon: "checkmark.circle.fill", text: text), duration: 1.8)
                    }
                }
            }
        }
    }

    private func wireEvents() {
        let moveMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMove(event) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: moveMask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMove(event) }
            return event
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleOutsideClick() }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleDragEnd() }
        }) { monitors.append(m) }
        // Mouse-ups inside our own panel never reach the global monitor; without this the drag
        // pasteboard counter goes stale and every later drag (sliders, scrubber) is treated as a file drag.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleDragEnd() }
            return event
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self else { return event }
            // NSEvent isn't Sendable; local monitors run on the main thread, so only pass a flag across.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self.handleKey(event) == nil }
            return consumed ? nil : event
        }) { monitors.append(m) }
    }

    // MARK: Event handling

    private func handleMove(_ event: NSEvent) {
        let point = NSEvent.mouseLocation
        if let frame = screen?.frame {
            let faceCenter = viewModel.isDocked
                ? CGPoint(x: frame.midX - viewModel.cutoutWidth / 2 - NotchViewModel.dockFaceWidth / 2, y: frame.maxY - viewModel.notchSize.height / 2)
                : CGPoint(x: frame.midX, y: frame.maxY - viewModel.notchSize.height - NotchViewModel.faceHeight / 2)
            env.companion.pointerMoved(vector: CGVector(dx: point.x - faceCenter.x, dy: faceCenter.y - point.y))
        }
        if event.type == .leftMouseDragged, handleDrag(at: point) { return }
        updateMouseInteractivity(at: point)

        let vm = viewModel
        if vm.isOpen {
            let inside = contentRect(for: vm.openSize).insetBy(dx: -14, dy: -14).contains(point)
            if inside {
                vm.pointerVisited = true
                closeWork?.cancel(); closeWork = nil
            } else if vm.pointerVisited, !vm.isTyping, !vm.isDropTargeted, vm.openReason != .drag || NSEvent.pressedMouseButtons == 0 {
                scheduleClose()
            }
        } else {
            guard Settings.shared.openTrigger == .hover else { return }
            if hotZone().contains(point) {
                guard openWork == nil else { return }
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.openWork = nil
                    if self.hotZone().contains(NSEvent.mouseLocation), NSEvent.pressedMouseButtons == 0 {
                        self.viewModel.open(reason: .hover)
                    }
                }
                openWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0.02, Settings.shared.hoverDelay), execute: work)
            } else {
                openWork?.cancel(); openWork = nil
            }
        }
    }

    /// Hovering here opens the panel (the notch row, not the assistant's face below it).
    private func hotZone() -> NSRect {
        let size = viewModel.closedSize
        var rect = contentRect(for: CGSize(width: size.width, height: viewModel.notchSize.height), offset: viewModel.closedOffsetX)
        rect = rect.insetBy(dx: -8, dy: -4)
        rect.size.height += 4 // include the very top pixel row
        return rect
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            let inside = self.contentRect(for: self.viewModel.openSize).insetBy(dx: -14, dy: -14).contains(NSEvent.mouseLocation)
            if !inside && !self.viewModel.isTyping { self.viewModel.close() }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func updateMouseInteractivity(at point: NSPoint) {
        let rect = viewModel.isOpen
            ? contentRect(for: viewModel.openSize).insetBy(dx: -4, dy: -4)
            : hotZone()
        let shouldIgnore = !rect.contains(point)
        if panel.ignoresMouseEvents != shouldIgnore { panel.ignoresMouseEvents = shouldIgnore }
    }

    /// Opens the shelf when a file drag approaches the notch.
    private func handleDrag(at point: NSPoint) -> Bool {
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragChangeCount else { return false }
        let types = pb.types ?? []
        guard types.contains(.fileURL) || types.contains(.png) || types.contains(.tiff) || types.contains(.string) else { return false }
        let zone = contentRect(for: CGSize(width: viewModel.notchSize.width + 260, height: viewModel.notchSize.height + 70))
        if !viewModel.isOpen, zone.contains(point) {
            panel.ignoresMouseEvents = false
            viewModel.open(tab: .shelf, reason: .drag)
            return true
        }
        if viewModel.isOpen {
            panel.ignoresMouseEvents = !contentRect(for: viewModel.openSize).insetBy(dx: -20, dy: -20).contains(point)
            return true
        }
        return false
    }

    private func handleDragEnd() {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        if viewModel.isOpen, viewModel.openReason == .drag {
            let inside = contentRect(for: viewModel.openSize).contains(NSEvent.mouseLocation)
            if !inside { viewModel.close() }
        }
    }

    private func handleOutsideClick() {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        guard viewModel.isOpen else { return }
        if !contentRect(for: viewModel.openSize).contains(NSEvent.mouseLocation) {
            viewModel.close()
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard viewModel.isOpen, event.window === panel else { return event }
        if event.keyCode == 53 { // Esc
            viewModel.close()
            return nil
        }
        if event.modifierFlags.contains(.command), let ch = event.charactersIgnoringModifiers,
           let n = Int(ch), (1...NotchGroup.visible.count).contains(n) {
            viewModel.select(NotchGroup.visible[n - 1])
            return nil
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "," {
            onOpenSettings?()
            return nil
        }
        return event
    }
}

extension Notification.Name {
    static let notchMateCaptureSaved = Notification.Name("notchmate.captureSaved")
}
