// FocalPoint mac-virtual adapter — keyboard backlight driver + state renderer
//
// Uses the private CoreBrightness framework (KeyboardBrightnessClient) to
// drive the built-in keyboard backlight as a stand-in for FocalPoint's RGB
// matrix during pre-hardware validation. Private API: may break on future
// macOS versions; tested on macOS 14 (Apple Silicon).
//
// Usage:
//   focalpoint-backlight get            print current brightness (0.0-1.0)
//   focalpoint-backlight set <0.0-1.0>  set brightness
//   focalpoint-backlight run            connect to focalpointd and render agent
//                                    states as brightness patterns (Ctrl-C
//                                    restores the original brightness)
//
// MIT License - see adapters/README.md

import Foundation

// MARK: - Keyboard backlight via CoreBrightness

final class Backlight {
    private let client: NSObject
    private let getSel = NSSelectorFromString("brightnessForKeyboard:")
    private let setSel = NSSelectorFromString("setBrightness:forKeyboard:")
    private let supSel = NSSelectorFromString("isBacklightSuppressedOnKeyboard:")
    private let autoSel = NSSelectorFromString("enableAutoBrightness:forKeyboard:")
    private let isAutoSel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
    private typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias BoolFn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
    private typealias AutoFn = @convention(c) (AnyObject, Selector, Bool, UInt64) -> Bool
    private let getFn: GetFn
    private let setFn: SetFn
    private let supFn: BoolFn
    private let isAutoFn: BoolFn
    private let autoFn: AutoFn
    let keyboardID: UInt64

    init?() {
        guard dlopen(
            "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness",
            RTLD_NOW
        ) != nil,
            let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type
        else { return nil }
        let c = cls.init()
        guard let getM = c.method(for: getSel), let setM = c.method(for: setSel),
              let supM = c.method(for: supSel), let autoM = c.method(for: autoSel),
              let isAutoM = c.method(for: isAutoSel)
        else { return nil }
        client = c
        getFn = unsafeBitCast(getM, to: GetFn.self)
        setFn = unsafeBitCast(setM, to: SetFn.self)
        supFn = unsafeBitCast(supM, to: BoolFn.self)
        isAutoFn = unsafeBitCast(isAutoM, to: BoolFn.self)
        autoFn = unsafeBitCast(autoM, to: AutoFn.self)

        // Find a keyboard ID that actually accepts writes. ID 1 is the
        // built-in keyboard on every Mac tested (and what KBPulse uses);
        // the IDs from copyKeyboardBacklightIDs read fine but reject
        // setBrightness on at least the M2 Air, so verify with a write test.
        var candidates: [UInt64] = [1]
        let copySel = NSSelectorFromString("copyKeyboardBacklightIDs")
        typealias CopyFn = @convention(c) (AnyObject, Selector) -> NSArray?
        if let copyM = c.method(for: copySel),
           let ids = unsafeBitCast(copyM, to: CopyFn.self)(c, copySel) {
            for id in ids {
                if let n = id as? NSNumber { candidates.append(n.uint64Value) }
            }
        }
        let fadeSel = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
        typealias SetFadeFn =
            @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool
        var chosen: UInt64?
        if let fadeM = c.method(for: fadeSel) {
            let setF = unsafeBitCast(fadeM, to: SetFadeFn.self)
            let susSel = NSSelectorFromString("suspendIdleDimming:forKeyboard:")
            for kid in candidates {
                if let susM = c.method(for: susSel) {
                    _ = unsafeBitCast(susM, to: AutoFn.self)(c, susSel, true, kid)
                }
                let before = getFn(c, getSel, kid)
                let probe: Float = before > 0.5 ? before - 0.3 : before + 0.3
                _ = setF(c, fadeSel, probe, 0, true, kid)
                let after = getFn(c, getSel, kid)
                _ = setF(c, fadeSel, before, 0, true, kid)
                if let susM = c.method(for: susSel) {
                    _ = unsafeBitCast(susM, to: AutoFn.self)(c, susSel, false, kid)
                }
                if abs(after - probe) < 0.05 { chosen = kid; break }
            }
        }
        guard let kid = chosen else { return nil }
        keyboardID = kid
    }

    func brightness() -> Float {
        getFn(client, getSel, keyboardID)
    }

    /// True when macOS is suppressing the backlight (bright ambient light).
    /// While suppressed, set() is accepted but the LEDs stay dark.
    var suppressed: Bool {
        supFn(client, supSel, keyboardID)
    }

    var autoBrightness: Bool {
        isAutoFn(client, isAutoSel, keyboardID)
    }

    @discardableResult
    func setAutoBrightness(_ on: Bool) -> Bool {
        autoFn(client, autoSel, on, keyboardID)
    }

    /// Stop macOS from idle-dimming the backlight to 0 while no one types
    /// (it would immediately cancel our writes otherwise).
    @discardableResult
    func suspendIdleDimming(_ suspend: Bool) -> Bool {
        let sel = NSSelectorFromString("suspendIdleDimming:forKeyboard:")
        guard let m = client.method(for: sel) else { return false }
        return unsafeBitCast(m, to: AutoFn.self)(client, sel, suspend, keyboardID)
    }

    @discardableResult
    func set(_ value: Float, fadeMs: Int32 = 0) -> Bool {
        // setBrightness:fadeSpeed:commit:forKeyboard: — the variant working
        // implementations (KBPulse) use; fadeSpeed is a C int in ms.
        let sel = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
        typealias SetFadeFn =
            @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool
        if let m = client.method(for: sel) {
            return unsafeBitCast(m, to: SetFadeFn.self)(
                client, sel, max(0, min(1, value)), fadeMs, true, keyboardID)
        }
        return setFn(client, setSel, max(0, min(1, value)), keyboardID)
    }
}

// MARK: - focalpointd socket client

func socketPath() -> String {
    if let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !dir.isEmpty {
        return dir + "/focalpoint.sock"
    }
    return NSHomeDirectory() + "/.local/state/focalpoint/focalpoint.sock"
}

/// Connect to the daemon's unix socket. Returns the fd, or nil.
func connectDaemon() -> Int32? {
    let path = socketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
        let bytes = Array(path.utf8)
        guard bytes.count < buf.count else { return false }
        for (i, b) in bytes.enumerated() { buf[i] = b }
        return true
    }
    guard ok else { close(fd); return nil }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let res = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    guard res == 0 else { close(fd); return nil }
    return fd
}

func sendLine(_ fd: Int32, _ line: String) {
    let data = Array((line + "\n").utf8)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

/// Read newline-delimited JSON objects from fd, invoking handler per object.
func readLines(_ fd: Int32, handler: ([String: Any]) -> Void) {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nl)
            buffer.removeSubrange(...nl)
            if let obj = try? JSONSerialization.jsonObject(with: Data(lineData)),
               let dict = obj as? [String: Any] {
                handler(dict)
            }
        }
    }
}

// MARK: - State renderer

let stateNames = ["idle", "thinking", "running", "waiting", "done", "error"]

final class Renderer {
    private let lock = NSLock()
    private var state = "idle"
    private var enteredAt = Date()

    func setState(_ s: String) {
        guard stateNames.contains(s) else { return }
        lock.lock()
        if s != state {
            state = s
            enteredAt = Date()
            FileHandle.standardError.write(Data("state -> \(s)\n".utf8))
        }
        lock.unlock()
    }

    /// Brightness (0-1) for the current moment. Patterns mirror the default
    /// LED effects in PROTOCOL.md section 1, translated to a single channel.
    func brightness(idleLevel: Float) -> Float {
        lock.lock()
        let s = state
        let t = Float(Date().timeIntervalSince(enteredAt))
        lock.unlock()
        func sine(lo: Float, hi: Float, period: Float) -> Float {
            lo + (hi - lo) * (0.5 + 0.5 * sin(2 * .pi * t / period))
        }
        switch s {
        case "thinking": return sine(lo: 0.15, hi: 0.7, period: 2.5)   // slow pulse
        case "running":  return sine(lo: 0.2, hi: 0.9, period: 0.8)    // fast pulse
        case "waiting":  return t.truncatingRemainder(dividingBy: 0.8) < 0.4 ? 1.0 : 0.05
        case "done":     return t < 5 ? 1.0 : idleLevel                // solid, then idle
        case "error":    return t.truncatingRemainder(dividingBy: 0.25) < 0.125 ? 1.0 : 0.0
        default:         return idleLevel
        }
    }
}

// MARK: - main

let args = CommandLine.arguments
guard let backlight = Backlight() else {
    FileHandle.standardError.write(Data(
        "error: KeyboardBrightnessClient unavailable (no backlight, or macOS moved the private API)\n".utf8))
    exit(1)
}

switch args.count > 1 ? args[1] : "help" {
case "get":
    print(String(format: "%.3f", backlight.brightness()))

case "status":
    print("keyboardID: \(backlight.keyboardID)")
    print(String(format: "brightness: %.3f", backlight.brightness()))
    print("suppressed: \(backlight.suppressed)")
    print("autoBrightness: \(backlight.autoBrightness)")

case "set":
    guard args.count > 2, let v = Float(args[2]), v >= 0, v <= 1 else {
        FileHandle.standardError.write(Data("usage: focalpoint-backlight set <0.0-1.0>\n".utf8))
        exit(2)
    }
    // Idle dimming would zero a manual level within seconds; suspend it so
    // the set sticks (macOS restores normal behavior on sleep/login anyway).
    backlight.suspendIdleDimming(v > 0)
    exit(backlight.set(v, fadeMs: 350) ? 0 : 1)

case "run":
    let original = backlight.brightness()
    let wasAuto = backlight.autoBrightness
    let idleLevel = max(0.1, original)
    let renderer = Renderer()

    // Note: isBacklightSuppressedOnKeyboard has proven unreliable (reads true
    // while the LEDs are visibly controllable), so it is deliberately not
    // used to gate or warn about rendering.
    // Auto-brightness and idle dimming fight manual control; take over for
    // the session.
    if wasAuto { backlight.setAutoBrightness(false) }
    backlight.suspendIdleDimming(true)

    // Restore the user's settings on any exit path (Ctrl-C / TERM / normal).
    atexit_b {
        backlight.suspendIdleDimming(false)
        backlight.set(original)
        if wasAuto { backlight.setAutoBrightness(true) }
    }
    signal(SIGINT) { _ in exit(0) }
    signal(SIGTERM) { _ in exit(0) }

    // Reader thread: subscribe to daemon events; poll get-state as fallback
    // (state events on subscribe require daemon >= the state-broadcast change;
    // polling keeps this working against older daemons).
    Thread.detachNewThread {
        while true {
            if let fd = connectDaemon() {
                FileHandle.standardError.write(Data("connected to focalpointd\n".utf8))
                sendLine(fd, "{\"cmd\": \"subscribe\"}")
                readLines(fd) { obj in
                    if let ev = obj["event"] as? String, ev == "state",
                       let s = obj["state"] as? String {
                        renderer.setState(s)
                    }
                }
                close(fd)
                FileHandle.standardError.write(Data("daemon connection lost; retrying\n".utf8))
            }
            renderer.setState("idle")
            Thread.sleep(forTimeInterval: 2)
        }
    }
    Thread.detachNewThread {
        while true {
            if let fd = connectDaemon() {
                sendLine(fd, "{\"cmd\": \"get-state\"}")
                var got = false
                readLines(fd) { obj in
                    if !got, let s = obj["state"] as? String {
                        got = true
                        renderer.setState(s)
                    }
                }
                close(fd)
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    // Render loop: sample at 20 Hz but let the HARDWARE interpolate between
    // setpoints (fadeMs slightly longer than the sample interval), instead of
    // stepping the level instantly — stepped writes stutter visibly. Skip
    // writes when the target hasn't moved (blink plateaus, solid states).
    var last: Float = -1
    while true {
        let v = renderer.brightness(idleLevel: idleLevel)
        if abs(v - last) > 0.005 {
            backlight.set(v, fadeMs: 80)
            last = v
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

default:
    print("""
    focalpoint-backlight — MacBook keyboard backlight as a FocalPoint status light
      get            print current brightness
      set <0.0-1.0>  set brightness
      run            render focalpointd agent states (Ctrl-C restores brightness)
    """)
}
