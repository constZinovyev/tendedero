import Carbon

/// A global shortcut through the Carbon hot key API. Unlike a global key
/// monitor, it needs no Accessibility permission. All shortcuts share one
/// event handler and are told apart by their id. A key with `released`
/// is told when it is let go too, so it can be held down.
final class HotKey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private static var actions: [UInt32: () -> Void] = [:]
    private static var releases: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    init(keyCode: Int, modifiers: Int, action: @escaping () -> Void, released: (() -> Void)? = nil) {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.actions[id] = action
        HotKey.releases[id] = released
        HotKey.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5445_4E44), id: id) // "TEND"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var pressed = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let id = pressed.id
            let up = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async { (up ? HotKey.releases[id] : HotKey.actions[id])?() }
            return noErr
        }, 2, &specs, nil, nil)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.actions[id] = nil
        HotKey.releases[id] = nil
    }
}
