import AppKit
import Carbon.HIToolbox

/// User-configurable global hotkey. Modifier flags are Carbon constants
/// (cmdKey / optionKey / controlKey / shiftKey); keyCode is the same value
/// you'd pull off `NSEvent.keyCode`.
struct Hotkey: Codable, Equatable {
    var modifiers: UInt32
    var keyCode:   UInt32

    static let none           = Hotkey(modifiers: 0, keyCode: 0)
    static let defaultHotkey  = Hotkey(
        modifiers: UInt32(controlKey | optionKey),
        keyCode:   UInt32(kVK_ANSI_P)
    )

    var isSet: Bool { modifiers != 0 && keyCode != 0 }

    /// Compact human-readable string suitable for buttons: e.g. `⌃⌥P`.
    var display: String {
        guard isSet else { return "Not set" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        s += Self.keyName(keyCode)
        return s
    }

    /// Friendly name for a virtual key code. Covers letters, digits, function
    /// keys, and a handful of common navigation keys — falls back to "?".
    static func keyName(_ code: UInt32) -> String {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_Space: "Space", kVK_Return: "Return", kVK_Tab: "Tab",
            kVK_Delete: "Delete", kVK_Escape: "Esc",
            kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow:   "↑", kVK_DownArrow:  "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return map[Int(code)] ?? "?"
    }
}

/// Convert AppKit modifier flags into Carbon ones (the form Carbon's hotkey
/// API and our `Hotkey` struct use).
func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.shift)   { m |= UInt32(shiftKey) }
    if flags.contains(.option)  { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    return m
}

/// Registers a single global hotkey via Carbon's `RegisterEventHotKey`.
/// We use Carbon rather than `NSEvent.addGlobalMonitor` because the latter
/// requires Accessibility permission, while RegisterEventHotKey doesn't.
@MainActor
final class HotkeyManager {

    static let shared = HotkeyManager()

    /// Invoked on the main queue whenever the registered hotkey fires.
    var onPress: () -> Void = {}

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    func register(_ hotkey: Hotkey) {
        unregister()
        guard hotkey.isSet else { return }

        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x504B4559), id: 1)   // 'PKEY'
        let status = RegisterEventHotKey(
            hotkey.keyCode,
            hotkey.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr { hotKeyRef = ref }
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind:  UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { mgr.onPress() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }
}
