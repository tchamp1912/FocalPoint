// FocalPoint menu-bar app — protocol model (states, styles, defaults).
// See /Users/tommy/Documents/Projects/focalpoint/PROTOCOL.md §1 and §3.
// MIT License.

import SwiftUI

// MARK: - Agent states (PROTOCOL.md §1)

enum AgentState: String, CaseIterable, Identifiable, Codable {
    case idle, thinking, running, waiting, done, error
    var id: String { rawValue }

    /// Aggregate ordering: error > waiting > running > thinking > done > idle.
    var severity: Int {
        switch self {
        case .error:    return 5
        case .waiting:  return 4
        case .running:  return 3
        case .thinking: return 2
        case .done:     return 1
        case .idle:     return 0
        }
    }

    var display: String {
        switch self {
        case .idle:     return "Idle"
        case .thinking: return "Thinking"
        case .running:  return "Running"
        case .waiting:  return "Waiting"
        case .done:     return "Done"
        case .error:    return "Error"
        }
    }

    /// True when this state should raise a menu-bar attention badge.
    var needsAttention: Bool { self == .waiting || self == .error }

    /// SF Symbol shown instead of a plain color dot — a distinct outline
    /// shape reads faster at a glance than color alone. Tinted with the
    /// state's configured color, so "colored" carries over from the dot.
    var symbolName: String {
        switch self {
        case .idle:     return "moon.zzz"
        case .thinking: return "brain"
        case .running:  return "bolt"
        case .waiting:  return "hourglass"
        case .done:     return "checkmark"
        case .error:    return "exclamationmark.triangle"
        }
    }
}

// MARK: - Render patterns (PROTOCOL.md §2 SET_STATE_STYLE / §3 Styles)

enum Pattern: String, CaseIterable, Identifiable {
    case solid, breathe, blink, strobe, off
    var id: String { rawValue }
    var display: String { rawValue.capitalized }
}

// MARK: - A per-state render style

struct StateStyle: Equatable {
    var rgb: [Int]          // 0-255, length 3
    var pattern: Pattern
    var periodMs: Int

    var color: Color {
        let r = Double(rgb.count > 0 ? rgb[0] : 0) / 255.0
        let g = Double(rgb.count > 1 ? rgb[1] : 0) / 255.0
        let b = Double(rgb.count > 2 ? rgb[2] : 0) / 255.0
        return Color(red: r, green: g, blue: b)
    }
}

// MARK: - Default styles (PROTOCOL.md §1 "Default LED effect")

// The §1 table gives effects in words; these are the concrete RGB + pattern +
// period the app ships as defaults and sends on "reset to defaults". The
// waiting entry matches the example in PROTOCOL.md §3/§5 (dodger blue blink).
let defaultStyles: [AgentState: StateStyle] = [
    .idle:     StateStyle(rgb: [64, 64, 64],   pattern: .breathe, periodMs: 4000),
    .thinking: StateStyle(rgb: [160, 32, 240], pattern: .breathe, periodMs: 2500),
    .running:  StateStyle(rgb: [255, 176, 0],  pattern: .breathe, periodMs: 800),
    .waiting:  StateStyle(rgb: [30, 144, 255], pattern: .blink,   periodMs: 800),
    .done:     StateStyle(rgb: [0, 200, 0],    pattern: .solid,   periodMs: 1000),
    .error:    StateStyle(rgb: [255, 0, 0],    pattern: .blink,   periodMs: 250),
]

func defaultStyle(_ s: AgentState) -> StateStyle {
    defaultStyles[s] ?? StateStyle(rgb: [128, 128, 128], pattern: .solid, periodMs: 1000)
}

// MARK: - Live session record

/// A well-known optional per-session stat an adapter may report via
/// `set-state --meta key=value` (PROTOCOL.md §4). Every stat is opt-in on
/// both ends: an adapter reports whatever it can, and the UI (Settings →
/// Claude & Codex) shows a badge only for stats the user has enabled AND
/// the current session actually has data for.
enum SessionStat: String, CaseIterable, Identifiable {
    case tokensIn = "tokens_in"
    case tokensOut = "tokens_out"
    case toolCalls = "tool_calls"
    case turns = "turns"
    case subagents = "subagents"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tokensIn:  return "Tokens in"
        case .tokensOut: return "Tokens out"
        case .toolCalls: return "Tool calls"
        case .turns:     return "Turns"
        case .subagents: return "Subagents"
        }
    }

    var symbol: String {
        switch self {
        case .tokensIn:  return "arrow.down.circle"
        case .tokensOut: return "arrow.up.circle"
        case .toolCalls: return "wrench.and.screwdriver"
        case .turns:     return "arrow.triangle.2.circlepath"
        case .subagents: return "person.2"
        }
    }

    /// Compact display for a badge: "12.4k" instead of "12421".
    func format(_ value: Double) -> String {
        switch self {
        case .tokensIn, .tokensOut:
            if value >= 1000 { return String(format: "%.1fk", value / 1000) }
            return String(Int(value))
        case .toolCalls, .turns, .subagents:
            return String(Int(value))
        }
    }
}

struct SessionInfo: Identifiable, Equatable {
    let id: String          // session id
    var kind: String
    var label: String?
    /// User-assigned name from `rename-session` (PROTOCOL.md §3). Distinct
    /// from `label`, which adapters overwrite on every state change.
    var name: String?
    var slot: Int?          // 1-12, or nil for slotless
    var state: AgentState
    var cwd: String?
    /// When this session was first seen (session registration), distinct
    /// from `lastChange` (last state transition). Used only for history's
    /// duration column — nothing in the live UI needs it.
    var firstSeen: Date
    var lastChange: Date
    var stats: [SessionStat: Double] = [:]

    /// Display precedence per PROTOCOL.md §3: name → label → kind.
    var title: String {
        for candidate in [name, label] where !(candidate ?? "").isEmpty {
            return candidate!
        }
        return kind
    }

    /// True when the user has renamed this session (drives "Reset name").
    var isRenamed: Bool { !(name ?? "").isEmpty }
}

// MARK: - Session history (persisted locally; see AppModel.sessionHistory)

/// A completed session, snapshotted at `"session-ended"` (explicit
/// `end-session` or TTL expiry — see PROTOCOL.md §3) before it's dropped from
/// the live `sessions` list. Persisted client-side; the daemon itself keeps
/// no history (PROTOCOL.md §3: session state "is not persisted across
/// `end-session`, TTL expiry, or a daemon restart").
struct SessionHistoryEntry: Identifiable, Codable, Equatable {
    let id: String          // fresh UUID; a session id could in principle repeat
    var sessionID: String
    var title: String
    var kind: String
    var cwd: String?
    var finalState: AgentState
    var startedAt: Date
    var endedAt: Date
    /// Keyed by `SessionStat.rawValue` rather than `[SessionStat: Double]`
    /// directly, to keep `Codable` conformance unambiguous.
    var statValues: [String: Double]

    var stats: [SessionStat: Double] {
        Dictionary(uniqueKeysWithValues: statValues.compactMap { key, value in
            SessionStat(rawValue: key).map { ($0, value) }
        })
    }
}

// MARK: - Provider account usage (PROTOCOL.md §3 Account usage)

/// Last-known subscription quota for a provider. Values originate from the
/// provider's supported local interface, never from estimated session tokens.
struct ProviderUsage: Identifiable, Equatable {
    let provider: String
    var values: [String: Double]
    var updatedAt: Date

    var id: String { provider }

    var fiveHourUsed: Double? { values["five_hour_used"] }
    var fiveHourResetsAt: Date? { epochDate("five_hour_resets_at") }
    var sevenDayUsed: Double? { values["seven_day_used"] }
    var sevenDayResetsAt: Date? { epochDate("seven_day_resets_at") }
    var primaryUsed: Double? { values["primary_used"] }
    var primaryResetsAt: Date? { epochDate("primary_resets_at") }
    var secondaryUsed: Double? { values["secondary_used"] }
    var secondaryResetsAt: Date? { epochDate("secondary_resets_at") }

    private func epochDate(_ key: String) -> Date? {
        guard let seconds = values[key], seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

// MARK: - Relative time formatting

func elapsedString(since date: Date, now: Date = Date()) -> String {
    let s = max(0, Int(now.timeIntervalSince(date)))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    if h < 24 { return "\(h)h" }
    return "\(h / 24)d"
}

/// A fixed span (e.g. a completed session's total duration), unlike
/// `elapsedString`, which measures from a date to now.
func durationString(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    if s < 60 { return "\(s)s" }
    let m = s / 60
    if m < 60 { return "\(m)m \(s % 60)s" }
    let h = m / 60
    if h < 24 { return "\(h)h \(m % 60)m" }
    let d = h / 24
    return "\(d)d \(h % 24)h"
}
