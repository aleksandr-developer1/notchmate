import AudioToolbox
import CoreAudio
import Foundation

/// Output volume of the default device through CoreAudio.
@MainActor
final class SystemVolume: ObservableObject {
    @Published var volume: Float = 0.5
    @Published private(set) var isMuted = false
    private var timer: Timer?

    func start() {
        read()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
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
            isMuted = mute != 0
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
