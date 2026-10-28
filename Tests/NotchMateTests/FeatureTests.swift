import XCTest
import AppKit
import SwiftUI
@testable import NotchMate

final class FeatureTests: XCTestCase {
    // MARK: Updates

    func testVersionComparison() {
        XCTAssertTrue(AppRelease.isNewer("0.10.0", than: "0.9.1"))
        XCTAssertTrue(AppRelease.isNewer("0.9.2", than: "0.9.1"))
        XCTAssertTrue(AppRelease.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(AppRelease.isNewer("0.9.1", than: "0.9.1-beta"))
        XCTAssertFalse(AppRelease.isNewer("0.9.1", than: "0.9.1"))
        XCTAssertFalse(AppRelease.isNewer("0.9.0", than: "0.9.1"))
        XCTAssertFalse(AppRelease.isNewer("0.9.1-beta", than: "0.9.1"))
    }

    func testNewestReleaseSkipsDraftsAndOldVersions() {
        let json: [[String: Any]] = [
            ["tag_name": "v1.0.0", "draft": true, "html_url": "https://example.com/draft"],
            ["tag_name": "v0.9.2", "draft": false, "html_url": "https://example.com/0.9.2", "body": "  Fixes  "],
            ["tag_name": "v0.9.1", "draft": false, "html_url": "https://example.com/0.9.1"],
        ]
        let release = AppRelease.newest(in: json, newerThan: "0.9.1")
        XCTAssertEqual(release?.version, "0.9.2")
        XCTAssertEqual(release?.notes, "Fixes")
        XCTAssertNil(AppRelease.newest(in: json, newerThan: "0.9.2"))
    }

    func testReleaseAssetComesOnlyFromGitHub() {
        let entry: [String: Any] = ["assets": [
            ["name": "notes.txt", "browser_download_url": "https://github.com/a/b/notes.txt"],
            ["name": "NotchMate-0.9.2-arm64.zip", "size": 8_731_288, "digest": "sha256:ABCDEF",
             "browser_download_url": "https://github.com/aleksandr-developer1/notchmate/releases/download/v0.9.2/NotchMate-0.9.2-arm64.zip"],
        ]]
        let asset = AppRelease.asset(in: entry)
        XCTAssertEqual(asset?.size, 8_731_288)
        XCTAssertEqual(asset?.sha256, "abcdef")
        XCTAssertNil(AppRelease.asset(in: ["assets": [["name": "NotchMate-1.zip", "browser_download_url": "https://evil.example/NotchMate-1.zip"]]]))
        XCTAssertNil(AppRelease.asset(in: ["assets": [["name": "NotchMate-1.zip", "browser_download_url": "http://github.com/NotchMate-1.zip"]]]))
    }

    func testUpdateArchiveIsUnpackedCheckedAndSwappedIn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("update-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func makeApp(at url: URL, version: String) throws {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": "com.test.notchmate", "CFBundleShortVersionString": version,
                                        "CFBundleExecutable": "NotchMate", "CFBundlePackageType": "APPL"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
            try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: contents.appendingPathComponent("MacOS/NotchMate").path)
            XCTAssertEqual(try shell("/usr/bin/codesign", ["--force", "--sign", "-", url.path]), 0)
        }
        // A release archive, like the one build.sh produces.
        let staged = root.appendingPathComponent("staged/NotchMate.app")
        try makeApp(at: staged, version: "9.9.9")
        let zip = root.appendingPathComponent("NotchMate-9.9.9-arm64.zip")
        XCTAssertEqual(try shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", staged.path, zip.path]), 0)
        let digest = try UpdateInstaller.sha256(of: zip)
        XCTAssertEqual(digest.count, 64)

        let copy = root.appendingPathComponent("copy.zip")
        try FileManager.default.copyItem(at: zip, to: copy)
        do {
            _ = try await UpdateInstaller.unpack(copy, expectingVersion: "1.0.0", bundleID: "com.test.notchmate")
            XCTFail("A different version must be refused")
        } catch {}
        let unpacked = try await UpdateInstaller.unpack(zip, expectingVersion: "9.9.9", bundleID: "com.test.notchmate")

        // The installed copy is replaced once the (stand-in) app process exits.
        let installed = root.appendingPathComponent("Applications/NotchMate.app")
        try makeApp(at: installed, version: "1.0.0")
        let running = Process()
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["0.4"]
        try running.run()
        try UpdateInstaller.relaunch(replacing: installed, with: unpacked, waitingFor: running.processIdentifier, launch: false)
        var version: String?
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            version = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
            if version == "9.9.9" { break }
        }
        XCTAssertEqual(version, "9.9.9")
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.path + ".previous"))
        XCTAssertNil(UpdateInstaller.problem(installingOver: installed))
    }

    /// Downloads a real release archive; runs only with NOTCHMATE_NETWORK_TESTS=1.
    func testDownloadsRealReleaseArchive() async throws {
        guard ProcessInfo.processInfo.environment["NOTCHMATE_NETWORK_TESTS"] == "1" else { throw XCTSkip("Network test") }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/aleksandr-developer1/notchmate/releases/tags/v0.9.1")!)
        let entry = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let asset = try XCTUnwrap(AppRelease.asset(in: entry))
        XCTAssertNotNil(asset.sha256)
        let zip = try await UpdateInstaller.download(asset) { _ in }
        defer { try? FileManager.default.removeItem(at: zip) }
        let app = try await UpdateInstaller.unpack(zip, expectingVersion: "0.9.1", bundleID: "com.aleksandrkezikov.notchmate")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/MacOS/NotchMate").path))
        try? FileManager.default.removeItem(at: app.deletingLastPathComponent())
    }

    private func shell(_ tool: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: Headphones

    func testHeadphonesBatteryParsesConnectedDevice() throws {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"Magic Trackpad":{"device_minorType":"Magic Trackpad"}},
          {"AirPods Pro":{"device_batteryLevelCase":"32\\u00a0%","device_batteryLevelLeft":"100\\u00a0%","device_batteryLevelRight":"95 %"}}
        ],"device_not_connected":[{"Old AirPods":{"device_batteryLevelLeft":"10 %"}}]}]}
        """
        let battery = try XCTUnwrap(HeadphonesBattery.parse(Data(json.utf8), name: "AirPods Pro"))
        XCTAssertEqual(battery, HeadphonesBattery(name: "AirPods Pro", left: 100, right: 95, caseLevel: 32, main: nil))
        XCTAssertEqual(battery.lowest, 95)
        // The audio name can differ from the Bluetooth one; a single battery device is still found.
        XCTAssertEqual(HeadphonesBattery.parse(Data(json.utf8), name: "Наушники")?.name, "AirPods Pro")
        XCTAssertNil(HeadphonesBattery.parse(Data("{}".utf8), name: "AirPods Pro"))
    }

    // MARK: Weather

    func testWeatherParsesAndWarnsAboutRain() throws {
        let now = Date(timeIntervalSince1970: 1_793_142_900)
        let json = """
        {"current":{"temperature_2m":6.4,"weather_code":3,"is_day":1},
         "hourly":{"time":[1793142000,1793145600,1793149200,1793152800],
                   "temperature_2m":[6.1,5.9,5.6,5.5],"weather_code":[3,3,61,61],"precipitation_probability":[0,20,70,80]}}
        """
        let report = try XCTUnwrap(WeatherReport.parse(Data(json.utf8)))
        XCTAssertEqual(Int(report.temperature.rounded()), 6)
        XCTAssertEqual(report.symbol, "cloud.fill")
        XCTAssertEqual(report.hours.count, 4)
        XCTAssertEqual(report.precipitationSoon(after: now)?.time, Date(timeIntervalSince1970: 1_793_149_200))
        XCTAssertNil(report.precipitationSoon(after: now, window: 1800))

        let raining = WeatherReport(temperature: 5, code: 61, isDay: true, hours: report.hours)
        XCTAssertNil(raining.precipitationSoon(after: now), "No warning while it already rains")
        XCTAssertEqual(WeatherCode.symbol(0, isDay: false), "moon.stars.fill")
        XCTAssertTrue(WeatherCode.isSnow(73))
    }

    // MARK: Calendar

    @MainActor
    func testMeetingLinkFoundInEventText() {
        XCTAssertEqual(CalendarService.meetingLink(in: "Join: https://meet.google.com/abc-defg-hij (Google Meet)")?.absoluteString,
                       "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(CalendarService.meetingLink(in: "Ссылка https://telemost.yandex.ru/j/123456")?.host(), "telemost.yandex.ru")
        XCTAssertNil(CalendarService.meetingLink(in: "Office, room 4 https://example.com/agenda"))
    }

    // MARK: Diagnostics

    @MainActor
    func testReportHidesHomeFolder() async {
        XCTAssertEqual(Diagnostics.sanitize("open \(NSHomeDirectory())/notes.md"), "open ~/notes.md")
        let report = await Diagnostics.report()
        XCTAssertTrue(report.hasPrefix("NotchMate "))
        XCTAssertTrue(report.contains("Plugins on:"))
        XCTAssertFalse(report.contains(NSHomeDirectory()))
    }

    // MARK: Rendering

    /// Every page and the new cards lay out without crashing; set NOTCHMATE_PREVIEW_DIR to look at them.
    @MainActor
    func testPagesRender() throws {
        _ = NSApplication.shared
        let env = AppEnvironment.shared
        let vm = NotchViewModel(env: env)
        // Notes pages talk to other apps on appear; they are left out.
        for tab in NotchTab.allCases where tab != .notes && tab != .obsidian {
            vm.tab = tab
            try render(PagePreview().notchEnvironment(env, viewModel: vm).frame(width: 660, height: 420), name: "tab-\(tab.rawValue)")
        }
        for page in 0..<4 {
            for dark in [false, true] {
                try render(WelcomeView(page: page) {}, name: "welcome-\(page + 1)-\(dark ? "dark" : "light")", dark: dark)
            }
        }
        let moods: [Mood] = [.idle, .startup, .happy, .love, .sleepy, .focused, .excited, .surprised, .tired, .music, .eating, .wink,
                             .alert, .message, .shutter, .call, .sad, .proud, .nod, .agent, .ready, .disappointed, .relax, .flow,
                             .bored, .fishing, .basketball, .watch, .breathe, .stressed, .zen, .charged, .drained]
        for mood in moods {
            // A few moments of each scene, so props in motion are checked too.
            for (i, time) in [0.3, 1.2, 2.1].enumerated() {
                try render(FaceView(mood: mood, scale: 2, sceneTime: time).padding(6).background(Color.black), name: "face-\(mood.rawValue)-\(i)")
            }
        }
        let battery = HeadphonesBattery(name: "AirPods Pro", left: 100, right: 15, caseLevel: 60, main: nil)
        try render(HeadphonesHUD(battery: battery).padding(.horizontal, 14).frame(width: 360, height: 44).background(Color.black), name: "headphones")
    }

    @MainActor
    private func render<V: View>(_ view: V, name: String, dark: Bool = true) throws {
        let hosting = NSHostingView(rootView: view.preferredColorScheme(dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 1), height: max(size.height, 1)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: hosting.frame.width, height: hosting.frame.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, name)
        if let dir = ProcessInfo.processInfo.environment["NOTCHMATE_PREVIEW_DIR"] {
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}

private struct PagePreview: View {
    @Namespace private var ns
    var body: some View { ExpandedView(ns: ns).background(Color.black) }
}
