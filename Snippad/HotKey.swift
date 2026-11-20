import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Carbon's RegisterEventHotKey is still the
/// only way to get one that needs no Accessibility or Input Monitoring
/// permission. One event handler serves every HotKey; each has its own id.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let action: () -> Void

    private static var handler: EventHandlerRef?
    private static var registered: [UInt32: HotKey] = [:]
    private static var nextID: UInt32 = 1

    /// `keyCode` is a virtual key code (kVK_ANSI_V); `modifiers` Carbon flags
    /// (cmdKey | controlKey).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action
        id = Self.nextID
        Self.nextID += 1
        guard Self.installHandler() else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E_5044) /* SNPD */, id: id)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
        Self.registered[id] = self
    }

    private static func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.registered[id]?.action() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
        return status == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.registered[id] = nil
    }
}
