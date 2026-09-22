import Foundation
import IOKit.ps

@MainActor
final class BatteryMonitor: ObservableObject {
    @Published private(set) var level: Int = 100
    @Published private(set) var isCharging = false
    @Published private(set) var isPluggedIn = false
    @Published private(set) var hasBattery = false
    @Published private(set) var timeRemaining: Int? // minutes

    /// Fires when the power adapter gets connected.
    var onPlugged: (() -> Void)?
    /// Fires once when the level drops to 20% while unplugged.
    var onLow: (() -> Void)?

    private var source: CFRunLoopSource?
    private var previousLevel = 100

    func start() {
        refresh(initial: true)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { monitor.refresh(initial: false) } }
        }, ctx)?.takeRetainedValue() {
            source = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
    }

    private func refresh(initial: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            level = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let t = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
            timeRemaining = t > 0 ? t : nil
            if plugged && !isPluggedIn && !initial { onPlugged?() }
            let newLevel = level
            if !initial, !plugged, newLevel <= 20, previousLevel > 20 { onLow?() }
            previousLevel = newLevel
            isPluggedIn = plugged
        }
    }
}
