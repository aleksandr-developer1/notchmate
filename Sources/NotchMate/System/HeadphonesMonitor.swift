import CoreAudio
import Foundation

/// Battery of a Bluetooth headset, as macOS reports it.
struct HeadphonesBattery: Equatable {
    var name: String
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    /// Over-ear and single-battery devices.
    var main: Int?

    var lowest: Int? { [left, right, main].compactMap { $0 }.min() }
    var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && main == nil }

    /// Reads `system_profiler SPBluetoothDataType -json`. Prefers the connected device called `name`.
    static func parse(_ data: Data, name: String) -> HeadphonesBattery? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var found: [HeadphonesBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (deviceName, value) in entry {
                    guard let info = value as? [String: Any] else { continue }
                    func level(_ key: String) -> Int? {
                        guard let text = info[key] as? String else { return nil }
                        return Int(text.filter(\.isNumber))
                    }
                    let battery = HeadphonesBattery(name: deviceName, left: level("device_batteryLevelLeft"), right: level("device_batteryLevelRight"),
                                                    caseLevel: level("device_batteryLevelCase"), main: level("device_batteryLevelMain"))
                    if !battery.isEmpty { found.append(battery) }
                }
            }
        }
        return found.first { $0.name == name } ?? found.first { name.contains($0.name) || $0.name.contains(name) } ?? (found.count == 1 ? found[0] : nil)
    }
}

/// Shows the headset's charge when sound switches to a Bluetooth device, like iPhone does for AirPods.
@MainActor
final class HeadphonesMonitor {
    var onConnected: ((HeadphonesBattery) -> Void)?

    private var listener: AudioObjectPropertyListenerBlock?
    private var lastDevice = AudioDeviceID(0)
    private var lastShown: [String: Date] = [:]

    private static var defaultOutput: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        guard listener == nil else { return }
        lastDevice = Self.currentDevice
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.deviceChanged() }
        }
        listener = block
        var address = Self.defaultOutput
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func deviceChanged() {
        let device = Self.currentDevice
        guard device != lastDevice else { return }
        lastDevice = device
        guard Settings.shared.headphonesHUD, Self.isBluetooth(device), let name = Self.name(of: device) else { return }
        // Reconnects in a row (case opened twice) show once.
        if let shown = lastShown[name], Date().timeIntervalSince(shown) < 120 { return }
        Task { [weak self] in
            // macOS fills in the battery levels a moment after the connection.
            try? await Task.sleep(for: .seconds(2))
            guard let battery = await Self.readBattery(name: name) else { return }
            self?.lastShown[name] = Date()
            self?.onConnected?(battery)
        }
    }

    private static func readBattery(name: String) async -> HeadphonesBattery? {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return HeadphonesBattery.parse(data, name: name)
        }.value
    }

    private static var currentDevice: AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultOutput
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    private static func isBluetooth(_ device: AudioDeviceID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func name(of device: AudioDeviceID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }
}
