import XCTest
import AppKit
import SwiftUI
@testable import NotchMate

final class PluginTests: XCTestCase {
    @MainActor
    func testCatalogRendersWithoutStartingBackgroundServices() async throws {
        _ = NSApplication.shared
        let size = NSSize(width: 700, height: 900)
        let hosting = NSHostingView(rootView: PluginCatalogView().environmentObject(AppEnvironment.shared)
            .frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        var colors = Set<String>()
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 35) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 35) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    colors.insert("\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255))")
                }
            }
        }
        XCTAssertGreaterThan(colors.count, 5, "The catalog must contain rendered content, not a blank surface")
        if let destination = ProcessInfo.processInfo.environment["NOTCHMATE_PLUGIN_PREVIEW_PATH"] {
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: destination))
        }
    }

    func testDisablingParentsAlsoDisablesOnlyTheirDependents() {
        XCTAssertEqual(PluginID.music.disabling, [.music])
        XCTAssertEqual(PluginID.notes.disabling, [.notes])
        XCTAssertEqual(PluginID.obsidian.disabling, [.obsidian])
        XCTAssertEqual(PluginID.ai.disabling, [.ai, .meetingAssistant])
        XCTAssertEqual(PluginID.calls.disabling, [.calls, .meetingAssistant])
        XCTAssertEqual(PluginID.jira.disabling, [.jira])
        XCTAssertFalse(PluginID.meetingAssistant.isEnabled(disabled: [PluginID.ai.rawValue]))
        XCTAssertTrue(PluginID.calls.isEnabled(disabled: [PluginID.ai.rawValue]))
    }

    func testDependenciesHaveNoCycles() {
        func visit(_ plugin: PluginID, ancestors: Set<PluginID>) {
            XCTAssertFalse(ancestors.contains(plugin), "Dependency cycle at \(plugin)")
            guard !ancestors.contains(plugin) else { return }
            for dependency in plugin.dependencies { visit(dependency, ancestors: ancestors.union([plugin])) }
        }
        for plugin in PluginID.allCases { visit(plugin, ancestors: []) }
    }

    @MainActor
    func testCatalogIsOnlyInSettingsWhenEveryPluginIsDisabled() throws {
        let name = "NotchMateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        settings.disabledPlugins = Set(PluginID.allCases.map(\.rawValue))
        let available = NotchTab.allCases.filter { $0.isAvailable(settings: settings) }
        XCTAssertTrue(available.isEmpty)
        XCTAssertNil(NotchTab(rawValue: "plugins"))
        XCTAssertNil(NotchGroup(rawValue: "plugins"))
        XCTAssertTrue(SettingsPage.allCases.contains(.integrations))
    }

    @MainActor
    func testExistingDisabledFeaturesArePreservedDuringMigration() throws {
        let name = "NotchMateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "gitEnabled")
        defaults.set(false, forKey: "calendarEnabled")
        defaults.set(false, forKey: "clipboardEnabled")
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.pluginEnabled(.git))
        XCTAssertFalse(settings.pluginEnabled(.calendar))
        XCTAssertFalse(settings.pluginEnabled(.clipboard))
        XCTAssertFalse(settings.pluginEnabled(.garmin))
        XCTAssertFalse(settings.pluginEnabled(.appleHealth))
        XCTAssertTrue(settings.pluginEnabled(.ai))
        XCTAssertTrue(settings.pluginEnabled(.notes))
    }

    @MainActor
    func testDisabledPluginsPersistWithoutDeletingIntegrationConfiguration() throws {
        let name = "NotchMateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("https://jira.example.test", forKey: "jiraURL")
        defaults.set("/tmp/example-vault", forKey: "vaultPath")
        let settings = Settings(defaults: defaults)
        settings.disabledPlugins.formUnion([PluginID.jira.rawValue, PluginID.notes.rawValue, "future-plugin"])
        let restored = Settings(defaults: defaults)
        XCTAssertFalse(restored.pluginEnabled(.jira))
        XCTAssertFalse(restored.pluginEnabled(.notes))
        XCTAssertFalse(restored.pluginEnabled(.obsidian))
        XCTAssertEqual(restored.jiraURL, "https://jira.example.test")
        XCTAssertEqual(restored.vaultPath, "/tmp/example-vault")
        XCTAssertTrue(restored.disabledPlugins.contains("future-plugin"))
    }
    @MainActor
    func testHealthSourcesSwitchIndependentlyAndKeepOneHealthPage() throws {
        let name = "NotchMateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "garminEnabled")
        defaults.set(true, forKey: "appleHealthEnabled")
        let settings = Settings(defaults: defaults)
        settings.disabledPlugins.insert(PluginID.garmin.rawValue)
        XCTAssertFalse(settings.pluginEnabled(.garmin))
        XCTAssertTrue(settings.pluginEnabled(.appleHealth))
        XCTAssertTrue(NotchTab.health.isAvailable(settings: settings))
        settings.disabledPlugins = [PluginID.appleHealth.rawValue]
        XCTAssertTrue(settings.pluginEnabled(.garmin))
        XCTAssertFalse(settings.pluginEnabled(.appleHealth))
        XCTAssertTrue(NotchTab.health.isAvailable(settings: settings))
        settings.disabledPlugins.insert(PluginID.garmin.rawValue)
        XCTAssertFalse(NotchTab.health.isAvailable(settings: settings))
        XCTAssertEqual(NotchTab.allCases.filter { $0.group == .health }, [.health])
    }

    @MainActor
    func testOldDisabledHealthAndDiscoRemainDisabledAfterMigration() throws {
        let name = "NotchMateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: "garminEnabled")
        defaults.set(true, forKey: "appleHealthEnabled")
        defaults.set(["health", "disco", "future-plugin"], forKey: "disabledPlugins")
        let settings = Settings(defaults: defaults)
        XCTAssertFalse(settings.healthEnabled)
        XCTAssertFalse(settings.discoAvailable)
        XCTAssertTrue(settings.pluginEnabled(.music))
        XCTAssertNil(PluginID(rawValue: "disco"))
        XCTAssertNil(PluginID(rawValue: "health"))
        settings.disabledPlugins.insert(PluginID.jira.rawValue)
        let restored = Settings(defaults: defaults)
        XCTAssertFalse(restored.discoEnabled)
        XCTAssertFalse(restored.healthEnabled)
        XCTAssertTrue(restored.disabledPlugins.contains("future-plugin"))
    }

    @MainActor
    func testMusicDiscoSettingPersistsAndRespectsMusicAvailability() throws {
        let name = "NotchMateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = Settings(defaults: defaults)
        settings.discoEnabled = false
        XCTAssertFalse(settings.discoAvailable)
        XCTAssertFalse(Settings(defaults: defaults).discoAvailable)
        settings.discoEnabled = true
        XCTAssertTrue(settings.discoAvailable)
        settings.disabledPlugins.insert(PluginID.music.rawValue)
        XCTAssertFalse(settings.discoAvailable)
    }

}
