import AppKit
import Combine

extension Notification.Name {
    static let notchMateEnergyChanged = Notification.Name("notchMateEnergyChanged")
}

/// Only optional UI work is suspended. Recording and work timers keep their own lifecycle.
@MainActor
final class EnergyPolicy: ObservableObject {
    static let shared = EnergyPolicy()

    struct State: Equatable {
        var suspended = false
        var reducedEffects = false
    }

    @Published private(set) var state = State()
    private var inactiveReasons = Set<String>()
    private var observers = Set<AnyCancellable>()

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (off, on, reason) in [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display"),
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session"),
        ] {
            observe(off, center: workspace) { $0.setInactive(reason, true) }
            observe(on, center: workspace) { $0.setInactive(reason, false) }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(.init("com.apple.screenIsLocked"), center: distributed) { $0.setInactive("lock", true) }
        observe(.init("com.apple.screenIsUnlocked"), center: distributed) { $0.setInactive("lock", false) }
        observe(.NSProcessInfoPowerStateDidChange, center: .default) { $0.refresh() }
        observe(ProcessInfo.thermalStateDidChangeNotification, center: .default) { $0.refresh() }
        refresh()
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter,
                         action: @escaping (EnergyPolicy) -> Void) {
        center.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            action(self)
        }.store(in: &observers)
    }

    private func setInactive(_ reason: String, _ inactive: Bool) {
        if inactive { inactiveReasons.insert(reason) } else { inactiveReasons.remove(reason) }
        refresh()
    }

    private func refresh() {
        let process = ProcessInfo.processInfo
        let next = State(suspended: !inactiveReasons.isEmpty,
                         reducedEffects: process.isLowPowerModeEnabled || process.thermalState == .serious || process.thermalState == .critical)
        guard next != state else { return }
        state = next
        NotificationCenter.default.post(name: .notchMateEnergyChanged, object: nil)
    }
}

/// Coalescible polling that reconfigures on power/settings changes and stops while suspended.
/// The interval is re-evaluated after every callback, so activity can change the cadence.
@MainActor
final class EnergyTimer {
    private var timer: Timer?
    private var observers = Set<AnyCancellable>()
    private let interval: () -> TimeInterval?
    private let action: () -> Void
    private let runsWhenSuspended: Bool

    init(runsWhenSuspended: Bool = false, interval: @escaping () -> TimeInterval?, action: @escaping () -> Void) {
        self.runsWhenSuspended = runsWhenSuspended
        self.interval = interval
        self.action = action
        _ = EnergyPolicy.shared
        for name in [Notification.Name.notchMateEnergyChanged, .notchMateSettingsChanged] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                self?.reschedule()
            }.store(in: &observers)
        }
        // Most settings persist in didSet without posting notchMateSettingsChanged.
        // Deliver after willSet so interval providers read the new value.
        Settings.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.reschedule()
        }.store(in: &observers)
        reschedule()
    }

    func reschedule() {
        timer?.invalidate()
        timer = nil
        guard runsWhenSuspended || !EnergyPolicy.shared.state.suspended,
              let delay = interval() else { return }
        let next = Timer(timeInterval: max(0.1, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.action()
                self.reschedule()
            }
        }
        next.tolerance = min(delay * 0.2, 1)
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    deinit { timer?.invalidate() }
}
