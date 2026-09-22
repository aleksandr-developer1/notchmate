import CoreGraphics
import Foundation

/// Typing intensity from system-wide event counters (no permission needed — counts only, never contents).
@MainActor
final class ActivityMonitor: ObservableObject {
    enum Intensity { case away, quiet, normal, flow }

    @Published private(set) var intensity: Intensity = .normal
    @Published private(set) var keysPerMinute: Double = 0
    /// Seconds the current intensity has lasted.
    private(set) var intensitySince = Date()

    private var samples: [(Date, UInt32)] = []
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    var duration: TimeInterval { Date().timeIntervalSince(intensitySince) }

    private func sample() {
        let now = Date()
        let keys = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
        samples.append((now, keys))
        samples.removeAll { now.timeIntervalSince($0.0) > 120 }
        if let first = samples.first, now.timeIntervalSince(first.0) >= 30 {
            let delta = Double(keys &- first.1)
            keysPerMinute = delta / now.timeIntervalSince(first.0) * 60
        }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let next: Intensity
        if idle > 60 { next = .away }
        else if keysPerMinute >= 150 { next = .flow }
        else if keysPerMinute < 8 { next = .quiet }
        else { next = .normal }
        if next != intensity {
            intensity = next
            intensitySince = now
        }
    }
}
