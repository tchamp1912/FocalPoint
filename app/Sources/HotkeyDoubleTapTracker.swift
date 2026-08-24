// FocalPoint menu-bar app — double-tap detection for the number hotkeys.
//
// A single tap of key1…key9 focuses the session in that slot (unchanged);
// a second tap on the same slot within the window selects the slot's
// workflow instead — the app focuses the run's lead, so accept/reject/PTT
// route to the workflow's orchestrator rather than one member. Pure state
// machine in a Foundation-only file so the window semantics are unit-
// testable without Carbon (see Tests/HotkeyDoubleTapTrackerTests.swift).
// MIT License.

import Foundation

struct HotkeyDoubleTapTracker {
    /// Maximum gap between taps that still reads as a double-tap. Slightly
    /// under macOS's default double-click interval feel — these are global
    /// hotkeys with modifier chords, which people tap slower than a mouse.
    var window: TimeInterval = 0.4
    private var lastSlot: Int?
    private var lastTap: Date?

    /// Record a tap of `slot`; returns true when this tap completes a
    /// double-tap (same slot as the previous tap, within the window).
    ///
    /// The single-tap action fires immediately on the first tap (no waiting
    /// to see whether a second tap comes): focusing the same session twice
    /// is harmless, so responsiveness beats disambiguation delay here.
    mutating func tap(slot: Int, at now: Date = Date()) -> Bool {
        defer { lastSlot = slot; lastTap = now }
        guard lastSlot == slot, let last = lastTap else { return false }
        return now.timeIntervalSince(last) <= window
    }
}
