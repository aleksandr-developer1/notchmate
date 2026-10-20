import AppKit
import XCTest
@testable import NotchMate

final class EnergyTimerTests: XCTestCase {
    @MainActor
    private func settle(_ seconds: Double = 0.3) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }

    @MainActor
    func testDisplaySleepStopsOptionalPollingAndWakeRestartsIt() async throws {
        let center = NSWorkspace.shared.notificationCenter
        var calls = 0
        let timer = EnergyTimer(interval: { 0.1 }, action: { calls += 1 })
        defer {
            center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            _ = timer
        }
        try await settle()
        XCTAssertGreaterThan(calls, 0)
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try await settle(0.05)
        let sleepingCalls = calls
        try await settle()
        XCTAssertEqual(calls, sleepingCalls)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await settle()
        XCTAssertGreaterThan(calls, sleepingCalls)
    }

    @MainActor
    func testRecordingPollingContinuesWithDisplayAsleep() async throws {
        let center = NSWorkspace.shared.notificationCenter
        var calls = 0
        let timer = EnergyTimer(runsWhenSuspended: true, interval: { 0.1 }, action: { calls += 1 })
        defer {
            center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            _ = timer
        }
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try await settle()
        XCTAssertTrue(EnergyPolicy.shared.state.suspended)
        XCTAssertGreaterThan(calls, 0)
    }

    @MainActor
    func testWakeDoesNotResumeWhileSessionIsStillInactive() async throws {
        let policy = EnergyPolicy.shared
        let center = NSWorkspace.shared.notificationCenter
        defer {
            center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
            center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        }
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try await settle(0.05)
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await settle(0.05)
        XCTAssertTrue(policy.state.suspended)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await settle(0.05)
        XCTAssertFalse(policy.state.suspended)
    }

    @MainActor
    func testDisabledPollingCanRestartAndReleasingTimerCancelsIt() async throws {
        var enabled = false
        var calls = 0
        var timer: EnergyTimer? = EnergyTimer(interval: { enabled ? 0.1 : nil }, action: { calls += 1 })
        try await settle()
        XCTAssertEqual(calls, 0)
        enabled = true
        NotificationCenter.default.post(name: .notchMateSettingsChanged, object: nil)
        try await settle()
        XCTAssertGreaterThan(calls, 0)
        timer = nil
        let stoppedCalls = calls
        try await settle()
        XCTAssertEqual(calls, stoppedCalls)
        XCTAssertNil(timer)
    }
}
