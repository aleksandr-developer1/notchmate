import AudioToolbox
import CoreAudio
import Foundation

/// Output volume of the default device through CoreAudio.
@MainActor
final class SystemVolume: ObservableObject {
    @Published var volume: Float = 0.5
    @Published private(set) var isMuted = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var observedDevice = AudioDeviceID(0)

    nonisolated private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        .init(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
              mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    func start() {
        guard listener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.observeDevice()
                self?.read()
            }
        }
        listener = block
        var address = Self.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        observeDevice()
        read()
    }

    private func observeDevice() {
        let next = device
        guard next != observedDevice, let listener else { return }
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
            var address = Self.outputAddress(selector)
            if observedDevice != 0 {
                AudioObjectRemovePropertyListenerBlock(observedDevice, &address, .main, listener)
            }
            if next != 0 {
                AudioObjectAddPropertyListenerBlock(next, &address, .main, listener)
            }
        }
        observedDevice = next
    }

    deinit {
        guard let listener else { return }
        var address = Self.defaultDeviceAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        if observedDevice != 0 {
            for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyMute] {
                var output = Self.outputAddress(selector)
                AudioObjectRemovePropertyListenerBlock(observedDevice, &output, .main, listener)
            }
        }
    }

    private var device: AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    func read() {
        var vol = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &vol) == noErr, abs(vol - volume) > 0.005 {
            volume = vol
        }
        var mute = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyMute
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &mute) == noErr {
            let muted = mute != 0
            if isMuted != muted { isMuted = muted }
        }
    }

    func set(_ value: Float) {
        var vol = Float32(max(0, min(1, value)))
        volume = vol
        let size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &addr, 0, nil, size, &vol)
        if isMuted && vol > 0 { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        var m = UInt32(muted ? 1 : 0)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        isMuted = muted
    }
}
