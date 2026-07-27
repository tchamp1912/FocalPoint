// FocalPoint menu-bar app — global hotkeys via Carbon RegisterEventHotKey.
// Works WITHOUT Accessibility permission. Handles press AND release so
// push-to-talk can map to inject press / release. PROTOCOL.md §3 inject.
//
// Bindings (keyCode + modifiers) are user-editable and persisted by AppModel;
// this file only owns the fixed action semantics (which control string /
// inject kind each action id dispatches) and the Carbon register/unregister
// mechanics. See SettingsView's HotkeysSettingsView for the recorder UI.
// MIT License.

import Carbon
import Foundation

/// A user-editable key combo: Carbon virtual keycode + Carbon modifier mask
/// (controlKey/optionKey/shiftKey/cmdKey bits, combinable). Persisted as JSON.
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
}

/// Stable identity for every bindable action. The raw value doubles as the
/// persistence key AND, for the `.keyTap` actions, the literal `control`
/// string sent to the daemon (PROTOCOL.md §3/§4 inject).
enum HotkeyActionID: String, CaseIterable, Codable, Identifiable {
    case key1, key2, key3, key4, key5, key6, key7, key8, key9
    case accept
    case reject
    case newTask = "new-task"
    case pushToTalk = "push-to-talk"
    case dialCW = "dial-cw"
    case dialCCW = "dial-ccw"
    case toggleWidget = "toggle-widget"
    case attentionNext = "attention-next"
    case attentionPrev = "attention-prev"
    case sessionNext = "session-next"
    case sessionPrev = "session-prev"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .key1, .key2, .key3, .key4, .key5, .key6, .key7, .key8, .key9:
            return "Focus Session \(rawValue.dropFirst(3))"
        case .accept:      return "Accept"
        case .reject:      return "Reject"
        case .newTask:     return "New Task"
        case .pushToTalk:  return "Push to Talk"
        case .dialCW:      return "Dial +1"
        case .dialCCW:     return "Dial -1"
        case .toggleWidget: return "Toggle Widget"
        case .attentionNext: return "Focus Next Attention Session"
        case .attentionPrev: return "Focus Previous Attention Session"
        case .sessionNext:   return "Focus Next Session"
        case .sessionPrev:   return "Focus Previous Session"
        }
    }

    /// What firing this action does. Semantics are NOT user-editable —
    /// only the keyCode/modifiers binding is.
    fileprivate var action: HotkeyAction {
        switch self {
        case .key1, .key2, .key3, .key4, .key5, .key6, .key7, .key8, .key9:
            return .keyTap(rawValue)
        case .accept:      return .keyTap("accept")
        case .reject:      return .keyTap("reject")
        case .newTask:     return .keyTap("new-task")
        case .pushToTalk:  return .ptt
        case .dialCW:      return .dial(1)
        case .dialCCW:     return .dial(-1)
        case .toggleWidget: return .toggleWidget
        case .attentionNext: return .focusNav(.attentionNext)
        case .attentionPrev: return .focusNav(.attentionPrev)
        case .sessionNext:   return .focusNav(.sessionNext)
        case .sessionPrev:   return .focusNav(.sessionPrev)
        }
    }

    /// Shipped default keycode — all default to Control+Option (below) so
    /// nothing changes for existing users until they customize a binding.
    fileprivate var defaultKeyCode: UInt32 {
        switch self {
        case .key1: return 0x12
        case .key2: return 0x13
        case .key3: return 0x14
        case .key4: return 0x15
        case .key5: return 0x17
        case .key6: return 0x16
        case .key7: return 0x1A
        case .key8: return 0x1C
        case .key9: return 0x19
        case .accept:     return 0x00
        case .reject:     return 0x0F
        case .newTask:    return 0x2D
        case .pushToTalk: return 0x31
        case .dialCW:     return 0x18
        case .dialCCW:    return 0x1B
        case .toggleWidget: return 0x04   // 'h', mnemonic for "hide"
        case .attentionNext: return 0x7C  // Right arrow
        case .attentionPrev: return 0x7B  // Left arrow
        case .sessionNext:   return 0x7D  // Down arrow
        case .sessionPrev:   return 0x7E  // Up arrow
        }
    }

    var defaultBinding: HotkeyBinding {
        HotkeyBinding(keyCode: defaultKeyCode, modifiers: HotkeyActionID.defaultModifiers)
    }

    /// Control+Option — the fixed combo every action used before bindings
    /// became user-editable.
    static let defaultModifiers: UInt32 = UInt32(controlKey) | UInt32(optionKey)

    static var defaultBindings: [HotkeyActionID: HotkeyBinding] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultBinding) })
    }
}

/// Which way a focus-navigation hotkey moves. App-local: the app (not the
/// daemon) computes "next session" from its own session list and lastChange
/// timestamps, then taps that session's numbered key via the existing focus
/// path — see AppModel's `focus*Session()` methods.
enum FocusNavDirection {
    case attentionNext, attentionPrev, sessionNext, sessionPrev
}

/// What a hotkey does when it fires.
private enum HotkeyAction {
    case keyTap(String)          // inject key <control> tap on press
    case ptt                     // inject key push-to-talk: press/release
    case dial(Int)               // inject dial <delta> on press
    case toggleWidget            // app-local: flip desktop widget visibility, no daemon involved
    case focusNav(FocusNavDirection) // app-local: compute + tap the next/prev session's key
}

private let signature: FourCharCode = {
    let s = "FocP"
    var code: FourCharCode = 0
    for b in s.utf8 { code = (code << 8) + FourCharCode(b) }
    return code
}()

// C callback trampoline — must be a bare function pointer.
private func hotkeyHandler(_ next: EventHandlerCallRef?,
                           _ event: EventRef?,
                           _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event = event, let userData = userData else { return noErr }
    let mgr = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    var hkID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    guard status == noErr else { return noErr }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    mgr.fire(id: hkID.id, pressed: pressed)
    return noErr
}

final class HotkeyManager {
    private var refs: [UInt32: EventHotKeyRef] = [:]       // Carbon hotkey id -> ref
    private var idToAction: [UInt32: HotkeyActionID] = [:] // Carbon hotkey id -> action
    private var handler: EventHandlerRef?
    private var registered = false
    private let inject: ([String: Any]) -> Void
    private let toggleWidget: () -> Void
    private let focusNav: (FocusNavDirection) -> Void
    private var bindings: [HotkeyActionID: HotkeyBinding]

    init(bindings: [HotkeyActionID: HotkeyBinding], inject: @escaping ([String: Any]) -> Void,
         toggleWidget: @escaping () -> Void, focusNav: @escaping (FocusNavDirection) -> Void) {
        self.bindings = bindings
        self.inject = inject
        self.toggleWidget = toggleWidget
        self.focusNav = focusNav
    }

    func fire(id: UInt32, pressed: Bool) {
        guard let actionID = idToAction[id] else { return }
        switch actionID.action {
        case .keyTap(let control):
            // "tap" is press+release; fire once, on key-down only.
            if pressed {
                inject(["cmd": "inject", "kind": "key", "control": control, "action": "tap"])
            }
        case .ptt:
            inject(["cmd": "inject", "kind": "key", "control": "push-to-talk",
                    "action": pressed ? "press" : "release"])
        case .dial(let delta):
            if pressed { inject(["cmd": "inject", "kind": "dial", "delta": delta]) }
        case .toggleWidget:
            if pressed { toggleWidget() }
        case .focusNav(let direction):
            if pressed { focusNav(direction) }
        }
    }

    func register() {
        guard !registered else { return }
        installHandlerIfNeeded()
        registerAllHotkeys()
        registered = true
        log("registered \(refs.count) global hotkeys")
    }

    func unregister() {
        guard registered else { return }
        unregisterAllHotkeys()
        if let handler = handler { RemoveEventHandler(handler); self.handler = nil }
        registered = false
        log("unregistered global hotkeys")
    }

    /// Called whenever Settings changes a binding. Unregister-then-reregister
    /// everything is the simplest correct approach (Carbon hotkey ids are
    /// cheap to reassign and this only runs on user edits, not per-keystroke).
    /// No-op on the Carbon side while hotkeys are disabled — the new bindings
    /// still take effect the next time the user re-enables them.
    func updateBindings(_ newBindings: [HotkeyActionID: HotkeyBinding]) {
        bindings = newBindings
        guard registered else { return }
        unregisterAllHotkeys()
        registerAllHotkeys()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler,
                            spec.count, &spec, selfPtr, &handler)
    }

    private func registerAllHotkeys() {
        var nextID: UInt32 = 1
        for actionID in HotkeyActionID.allCases {
            guard let binding = bindings[actionID] else { continue }
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: signature, id: nextID)
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, hkID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref = ref {
                refs[nextID] = ref
                idToAction[nextID] = actionID
            } else {
                log("failed to register hotkey \(actionID.rawValue): \(status)")
            }
            nextID += 1
        }
    }

    private func unregisterAllHotkeys() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        idToAction.removeAll()
    }
}
