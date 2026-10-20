import XCTest
@testable import NotchMate

final class AppleNotesTests: XCTestCase {
    private static let recentJSON = #"[{"id":"test-note","title":"Recent thought","folder":"Notes","modified":1700000000,"text":null}]"#

    @MainActor
    private func fixture() throws -> (Settings, UserDefaults, String) {
        let name = "NotchMateNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let settings = Settings(defaults: defaults)
        settings.disabledPlugins = []
        return (settings, defaults, name)
    }

    @MainActor
    func testAppleNotesRemainSelectedWhenSavedObsidianPreferenceIsDisabled() throws {
        let (settings, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.notesSource = .obsidian
        settings.disabledPlugins = [PluginID.obsidian.rawValue]
        XCTAssertTrue(settings.pluginEnabled(.notes))
        XCTAssertFalse(settings.pluginEnabled(.obsidian))
        XCTAssertEqual(settings.activeNotesSource, .apple)
        XCTAssertEqual(NotchTab.notes.plugin, .notes)
        XCTAssertEqual(NotchTab.obsidian.plugin, .obsidian)
        XCTAssertEqual(NotchTab.notes.group, NotchTab.obsidian.group)
        XCTAssertNil(NotchGroup(rawValue: "obsidian"))
    }

    @MainActor
    func testObsidianWorksWithoutAppleNotesAndBothCanBeDisabled() throws {
        let (settings, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.notesSource = .apple
        settings.disabledPlugins = [PluginID.notes.rawValue]
        XCTAssertTrue(settings.pluginEnabled(.obsidian))
        XCTAssertEqual(settings.activeNotesSource, .obsidian)
        settings.disabledPlugins.insert(PluginID.obsidian.rawValue)
        XCTAssertNil(settings.activeNotesSource)
    }

    @MainActor
    func testRecentNotesSurviveUnavailablePlaintext() async throws {
        let (settings, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AppleNotesService(settings: settings, runScript: { _, _ in .success(Self.recentJSON) })
        let hits = await service.search("Recent")
        XCTAssertEqual(hits.map(\.note.id), ["test-note"])
        XCTAssertEqual(service.recent.map(\.id), ["test-note"])
        XCTAssertNil(service.unavailableMessage)
    }

    @MainActor
    func testInvalidIndexIsReportedInsteadOfLookingLikeAnEmptyLibrary() async throws {
        let (settings, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AppleNotesService(settings: settings, runScript: { _, _ in .success("not JSON") })
        _ = await service.search("Recent")
        XCTAssertNotNil(service.unavailableMessage)
        XCTAssertFalse(service.isLoaded)
    }

    @MainActor
    func testCreationPermissionErrorIsVisibleAndCanRecoverAfterRetry() async throws {
        let (settings, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AppleNotesService(settings: settings, runScript: { operation, _ in
            switch operation {
            case .create: return .failure(.init(message: "test-permission-denied", accessDenied: true))
            default: return .success(Self.recentJSON)
            }
        })
        XCTAssertNil(service.createNote(title: "Thought", body: ""))
        XCTAssertTrue(service.lastCaptureMessage?.contains("test-permission-denied") == true)
        XCTAssertNotNil(service.unavailableMessage)
        service.refresh(force: true)
        _ = await service.search("Recent")
        XCTAssertNil(service.unavailableMessage)
        XCTAssertEqual(service.recent.count, 1)
    }

    @MainActor
    func testCreatingDuringAnIndexScanQueuesAFreshScan() async throws {
        let (settings, defaults, name) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let script = RacingScript()
        defer { script.release.signal() }
        let service = AppleNotesService(settings: settings, runScript: { script.run($0, $1) })
        service.refresh(force: true)
        for _ in 0..<80 where script.listCount == 0 { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertEqual(script.listCount, 1)
        XCTAssertNotNil(service.createNote(title: "New thought", body: "Body"))
        script.release.signal()
        for _ in 0..<80 {
            if script.listCount >= 2, service.recent.contains(where: { $0.id == "new-note" }) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThanOrEqual(script.listCount, 2)
        XCTAssertEqual(service.recent.first?.id, "new-note")
    }
}

private final class RacingScript: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var lists = 0
    var listCount: Int { lock.lock(); defer { lock.unlock() }; return lists }

    func run(_ operation: AppleNotesService.Operation, _ args: [String]) -> Result<String, AppleNotesService.NotesError> {
        switch operation {
        case .create: return .success(#"{"id":"new-note","folder":"Notes"}"#)
        case .list:
            lock.lock(); lists += 1; let index = lists; lock.unlock()
            if index == 1 {
                _ = release.wait(timeout: .now() + 3)
                return .success("[]")
            }
            return .success(#"[{"id":"new-note","title":"New thought","folder":"Notes","modified":1700000001,"text":"Body"}]"#)
        default: return .success("ok")
        }
    }
}
