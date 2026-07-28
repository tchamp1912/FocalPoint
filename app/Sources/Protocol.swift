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
    case cost = "cost_usd"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .tokensIn:  return "Tokens in"
        case .tokensOut: return "Tokens out"
        case .toolCalls: return "Tool calls"
        case .turns:     return "Turns"
        case .subagents: return "Subagents"
        case .cost:      return "Cost"
        }
    }

    var symbol: String {
        switch self {
        case .tokensIn:  return "arrow.down.circle"
        case .tokensOut: return "arrow.up.circle"
        case .toolCalls: return "wrench.and.screwdriver"
        case .turns:     return "arrow.triangle.2.circlepath"
        case .subagents: return "person.2"
        case .cost:      return "dollarsign.circle"
        }
    }

    /// Compact display for a badge: "12.4k" instead of "12421".
    func format(_ value: Double) -> String {
        switch self {
        case .tokensIn, .tokensOut, .toolCalls, .turns, .subagents:
            return compactCount(value)
        case .cost:
            // Below a cent, "$0.00" reads as "free" — show the extra digit.
            if value >= 0.01 { return String(format: "$%.2f", value) }
            return String(format: "$%.3f", value)
        }
    }
}

/// Compact k/M formatting for the plain-count stats (tokens in/out, tool
/// calls, turns, subagents), capped at 3 significant figures so badges stay
/// a predictable width regardless of magnitude:
///   42       -> "42"      (under 1000: plain integer, no scaling)
///   999      -> "999"
///   1234     -> "1.23k"   (1000...999999: scaled by 1k, "k" suffix)
///   12345    -> "12.3k"
///   123456   -> "123k"
///   1234567  -> "1.23M"   (1,000,000+: scaled by 1M, "M" suffix)
private func compactCount(_ value: Double) -> String {
    let scaled: Double
    let suffix: String
    if value >= 1_000_000 {
        scaled = value / 1_000_000
        suffix = "M"
    } else if value >= 1000 {
        scaled = value / 1000
        suffix = "k"
    } else {
        return String(Int(value))
    }
    // Decimal places chosen so the scaled number keeps ~3 significant
    // figures: 1 integer digit -> 2 decimals, 2 -> 1 decimal, 3+ -> 0.
    // (A value that rounds up into a new digit count at that precision,
    // e.g. 999,500 -> "1000k", is an accepted rare edge case.)
    let integerDigits = String(Int(scaled)).count
    let decimals = max(0, min(2, 3 - integerDigits))
    return String(format: "%.\(decimals)f%@", scaled, suffix)
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
    /// Raw model id reported by the adapter (e.g. "claude-opus-4-8-..."),
    /// straight from `meta["model"]` (PROTOCOL.md §4). Use `modelBadge` for
    /// display. Claude Code and Codex report it; Cursor currently does not.
    var model: String?
    /// When this session was first seen (session registration), distinct
    /// from `lastChange` (last state transition). Used only for history's
    /// duration column — nothing in the live UI needs it.
    var firstSeen: Date
    var lastChange: Date
    var stats: [SessionStat: Double] = [:]
    /// Current context-window occupancy from `meta["context_tokens"]`
    /// (PROTOCOL.md §4) — the latest usage snapshot, not the cumulative
    /// `tokens_in` stat. Rendered as a bar (`contextFraction`), not a badge,
    /// so it's a plain field like `model`/`cwd` rather than a `SessionStat`.
    var contextTokens: Double?
    /// Adapter-reported total context-window capacity from
    /// `meta["context_window"]`. Preferred over the model-name fallback.
    var reportedContextWindow: Double?

    /// Display precedence per PROTOCOL.md §3: name → label → kind.
    var title: String {
        for candidate in [name, label] where !(candidate ?? "").isEmpty {
            return candidate!
        }
        return kind
    }

    /// True when the user has renamed this session (drives "Reset name").
    var isRenamed: Bool { !(name ?? "").isEmpty }

    /// Short display label for `model` (e.g. "claude-opus-4-8-..." → "Opus"),
    /// or nil when no model has been reported yet.
    var modelBadge: String? { model.map(shortModelLabel) }

    /// How full the model's context window currently is, 0...1, or nil when
    /// either `contextTokens` or a window size is unknown — or, critically,
    /// when `contextTokens` already *exceeds* the assumed window. That's not
    /// just "cap it at 100%": a session actively running past an assumed
    /// window is proof the assumption is wrong (observed in practice — a
    /// session ran fine at ~389k tokens against a hardcoded 200k guess this
    /// used to ship with), and clamping to 1.0 would render a false "danger,
    /// about to truncate" red bar off an assumption already known to be
    /// broken. Falling back to `contextTokensDisplay` (a plain count, no
    /// implied ceiling) is more honest than a percentage we can't stand
    /// behind — see MenuContentView/DesktopOverlay for the fallback.
    ///
    /// `defaultWindow` is `AppModel.contextWindowOverride` (Settings →
    /// Agent Integrations) — a user-editable fallback rather than a
    /// hardcoded per-model-name guess, specifically because that guess kept
    /// going stale: it doesn't know a model's real window, and a new
    /// generation shipping a different one used to require a FocalPoint
    /// rebuild to correct, not just a Settings edit.
    func contextFraction(defaultWindow: Int?) -> Double? {
        guard let tokens = contextTokens,
              let window = effectiveContextWindow(defaultWindow: defaultWindow),
              window > 0,
              tokens <= window else {
            return nil
        }
        return tokens / window
    }

    /// The window value `contextFraction` would use, exposed separately so
    /// `ContextMeterView` can place its fixed-token tick marks against the
    /// same number rather than re-deriving it.
    func effectiveContextWindow(defaultWindow: Int?) -> Double? {
        reportedContextWindow ?? defaultWindow.map(Double.init)
    }

    /// Plain "389k ctx" formatting of `contextTokens`, shown when
    /// `contextFraction` is nil but a raw count is still available —
    /// unknown/exceeded window, not unknown usage.
    var contextTokensDisplay: String? {
        guard let tokens = contextTokens else { return nil }
        if tokens >= 1000 { return String(format: "%.0fk ctx", (tokens / 1000).rounded()) }
        return "\(Int(tokens)) ctx"
    }
}

/// Shortens a raw model id into a compact display label. Matches on the
/// well-known Claude family names case-insensitively; anything else passes
/// through truncated rather than being hidden, so a future/unknown model
/// still shows *something*.
func shortModelLabel(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("opus") { return "Opus" }
    if lower.contains("sonnet") { return "Sonnet" }
    if lower.contains("haiku") { return "Haiku" }
    return raw.count > 20 ? String(raw.prefix(20)) + "…" : raw
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

    /// Short meter label for the provider's primary quota window.
    var primaryMeterLabel: String {
        switch provider {
        case "cursor": return "API"
        case "codex": return "Primary"
        default: return "Primary"
        }
    }

    /// Short meter label for the provider's secondary quota window.
    var secondaryMeterLabel: String {
        switch provider {
        case "cursor": return "Auto"
        case "codex": return "Secondary"
        default: return "Secondary"
        }
    }

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
