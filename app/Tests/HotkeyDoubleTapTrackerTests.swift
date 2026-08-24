// Tests for HotkeyDoubleTapTracker — compile with
// Sources/HotkeyDoubleTapTracker.swift only (Foundation-only).
import Foundation

@main
enum HotkeyDoubleTapTrackerTests {
    static func main() {
        let t0 = Date()

        var tracker = HotkeyDoubleTapTracker()
        precondition(!tracker.tap(slot: 3, at: t0), "first tap is a single tap")
        precondition(!tracker.tap(slot: 4, at: t0 + 0.1), "different slot breaks the run")
        precondition(tracker.tap(slot: 4, at: t0 + 0.2), "same slot within the window completes a double-tap")

        var slow = HotkeyDoubleTapTracker()
        precondition(!slow.tap(slot: 7, at: t0))
        precondition(!slow.tap(slot: 7, at: t0 + 0.6), "a gap past the window is two single taps")

        var triple = HotkeyDoubleTapTracker()
        precondition(!triple.tap(slot: 1, at: t0))
        precondition(triple.tap(slot: 1, at: t0 + 0.2))
        precondition(triple.tap(slot: 1, at: t0 + 0.3),
                     "a third fast tap re-triggers — re-focusing the lead is harmless")

        print("HotkeyDoubleTapTrackerTests: PASS")
    }
}
