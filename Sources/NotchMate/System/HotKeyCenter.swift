import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon — needs no Accessibility permission.
@MainActor
final class HotKeyCenter {
    static let kVK_ANSI_N = UInt32(Carbon.kVK_ANSI_N)
    static let kVK_ANSI_M = UInt32(Carbon.kVK_ANSI_M)
    static let kVK_ANSI_Z = UInt32(Carbon.kVK_ANSI_Z)
    static let kVK_ANSI_H = UInt32(Carbon.kVK_ANSI_H)
    static let kVK_Space = UInt32(Carbon.kVK_Space)

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = hkID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { center.handlers[id]?() }
            }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    func register(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, handler: @escaping () -> Void) {
        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, carbonMods, EventHotKeyID(signature: OSType(0x5348544B), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            handlers[id] = handler
        }
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
}
