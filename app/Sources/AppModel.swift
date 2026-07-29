// FocalPoint menu-bar app — observable app state (main actor).
// Consumes the subscribe stream and one-shot responses; publishes UI state.
// MIT License.

import SwiftUI
import AppKit
import Combine

/// Persistent behavior for the desktop widget (Task 3). Replaces the old
/// plain on/off toggle so the widget can stay glanceable without being in
/// the way while nothing needs attention.
enum DesktopWidgetMode: String, CaseIterable, Identifiable {
    case always
    case autoHideIdle
    case hidden

    var id: String { rawValue }

    var display: String {
        switch self {
        case .always:      return "Always show"
        case .autoHideIdle: return "Auto-hide when idle"
        case .hidden:      return "Hidden"
        }
    }
}

/// How the "next/previous attention session" hotkeys order sessions that
/// need attention (waiting/error). Persisted like the other settings.
enum AttentionCycleOrder: String, CaseIterable, Identifiable {
    case oldestFirst      // ignores severity; longest-neglected session first
    case severityFirst    // error before waiting; oldest first within each

    var id: String { rawValue }

    var display: String {
        switch self {
        case .oldestFirst:   return "Oldest first"
        case .severityFirst: return "Errors before waiting"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Connection
    @Published var connected = false            // daemon socket up

    // Aggregate + sessions
    @Published var aggregate: AgentState = .idle
    @Published var sessions: [SessionInfo] = []
    @Published var sessionsSupported = false     // daemon emits session events / list-sessions
    @Published var usage: [ProviderUsage] = []
    @Published var usageSupported = false
    /// Completed sessions, newest first — snapshotted at `"session-ended"`
    /// (see `recordSessionEnded`), since the daemon itself keeps no history.
    /// Persisted client-side, capped at `maxSessionHistoryEntries`.
    @Published var sessionHistory: [SessionHistoryEntry] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(sessionHistory) {
                UserDefaults.standard.set(data, forKey: "sessionHistory")
            }
        }
    }
    private let maxSessionHistoryEntries = 200
    /// The session FocalPoint itself last told to come forward — via a row
    /// click, a `key1`–`9` hotkey, or an attention/session-nav hotkey (see
    /// `focusSession`). Best-effort, not a true "frontmost window" signal:
    /// the daemon has no concept of focus (Focus is a one-shot bounce, per
    /// PROTOCOL.md §3), and this can't see focus changes made outside
    /// FocalPoint (e.g. manually clicking a different terminal). Runtime-only,
    /// not persisted — a fresh launch has no known focus.
    @Published var focusedSessionID: String?

    // Styles
    @Published var styles: [AgentState: StateStyle] = defaultStyles
    @Published var stylesSupported = false       // daemon knows get-styles/set-style

    // A monotonically increasing tick to refresh relative times once a second.
    @Published var tick = 0

    // Settings (persisted)
    @Published var coloredIcon: Bool {
        didSet { UserDefaults.standard.set(coloredIcon, forKey: "coloredIcon") }
    }
    @Published var hotkeysEnabled: Bool {
        didSet { UserDefaults.standard.set(hotkeysEnabled, forKey: "hotkeysEnabled")
                 onHotkeysToggled?(hotkeysEnabled) }
    }
    /// Sparse overrides keyed by HotkeyActionID.rawValue — only actions the
    /// user has customized are present. Missing entries fall back to
    /// HotkeyActionID.defaultBinding (see `resolvedHotkeyBindings`), so
    /// shipping a NEW default action in a future version needs no migration.
    @Published var hotkeyBindings: [String: HotkeyBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(hotkeyBindings) {
                UserDefaults.standard.set(data, forKey: "hotkeyBindings")
            }
            onHotkeyBindingsChanged?(resolvedHotkeyBindings)
        }
    }
    /// Desktop widget visibility behavior. The DesktopOverlayController
    /// observes this (plus aggregate/sessions) directly via Combine, so no
    /// app-delegate wiring callback is needed here (unlike hotkeys, which
    /// touch a Carbon event handler that must be registered/unregistered).
    @Published var desktopWidgetMode: DesktopWidgetMode {
        didSet { UserDefaults.standard.set(desktopWidgetMode.rawValue, forKey: "desktopWidgetMode") }
    }
    /// Runtime-only override toggled by the "Toggle Widget" hotkey — hides
    /// the widget on demand without touching the persisted `desktopWidgetMode`
    /// setting. Deliberately not persisted: it resets on relaunch so the
    /// configured mode is what you get back.
    @Published var desktopWidgetHotkeyHidden = false
    /// Shared translucency for the desktop widget and settings window (1.0 =
    /// opaque, lower = more see-through). Applied as NSWindow.alphaValue by
    /// the controllers that own those windows.
    @Published var interfaceTranslucency: Double {
        didSet { UserDefaults.standard.set(interfaceTranslucency, forKey: "interfaceTranslucency") }
    }
    /// Which optional per-session stat badges to show next to the elapsed
    /// timer (Settings → Claude & Codex). A stat only actually renders for a
    /// session that has data for it, so enabling one that no adapter reports
    /// yet is harmless — see SessionStat.
    @Published var visibleStats: Set<SessionStat> {
        didSet {
            UserDefaults.standard.set(visibleStats.map(\.rawValue), forKey: "visibleStats")
        }
    }
    @Published var showUsage: Bool {
        didSet { UserDefaults.standard.set(showUsage, forKey: "showUsage") }
    }
    /// Show the model badge (e.g. "Opus") next to each session row. Claude
    /// Code only — see SessionInfo.modelBadge.
    @Published var showModelBadge: Bool {
        didSet { UserDefaults.standard.set(showModelBadge, forKey: "showModelBadge") }
    }
    @Published var codexUsageEnabled: Bool {
        didSet {
            UserDefaults.standard.set(codexUsageEnabled, forKey: "codexUsageEnabled")
            if codexUsageEnabled { codexUsageMonitor?.start() } else { codexUsageMonitor?.stop() }
        }
    }
    @Published var cursorUsageEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cursorUsageEnabled, forKey: "cursorUsageEnabled")
            if cursorUsageEnabled { cursorUsageMonitor?.start() } else { cursorUsageMonitor?.stop() }
        }
    }
    /// Ordering used by the attention-next/prev focus hotkeys.
    @Published var attentionCycleOrder: AttentionCycleOrder {
        didSet { UserDefaults.standard.set(attentionCycleOrder.rawValue, forKey: "attentionCycleOrder") }
    }
    /// Per-user budget thresholds (Settings → Agent Integrations → Budget
    /// alerts) — nil means "off". `object(forKey:)` (rather than
    /// `integer(forKey:)`/`double(forKey:)`, which default to 0) is what
    /// distinguishes "never set" / "cleared" from an actual 0 threshold.
    /// See `isOverBudget`.
    @Published var tokenBudget: Int? {
        didSet {
            if let tokenBudget {
                UserDefaults.standard.set(tokenBudget, forKey: "tokenBudget")
            } else {
                UserDefaults.standard.removeObject(forKey: "tokenBudget")
            }
        }
    }
    @Published var costBudget: Double? {
        didSet {
            if let costBudget {
                UserDefaults.standard.set(costBudget, forKey: "costBudget")
            } else {
                UserDefaults.standard.removeObject(forKey: "costBudget")
            }
        }
    }
    /// Minutes of no update before a session still showing an
    /// active-looking state (thinking/running/waiting) is treated as
    /// probably-stale — almost always because the underlying agent process
    /// died without a clean Stop/SessionEnd (crash, killed terminal, sleep)
    /// rather than because it's genuinely still working that long. nil turns
    /// this off. Deliberately much shorter than the daemon's own
    /// `session.ttl_minutes` (config.toml, default 60), which is a hard
    /// cutoff that ends the session outright — this is only an earlier,
    /// purely-visual heads-up; the daemon still owns actually ending it.
    /// See `isStale`.
    @Published var staleThresholdMinutes: Int? {
        didSet {
            if let staleThresholdMinutes {
                UserDefaults.standard.set(staleThresholdMinutes, forKey: "staleThresholdMinutes")
            } else {
                UserDefaults.standard.removeObject(forKey: "staleThresholdMinutes")
            }
        }
    }
    /// Assumed context-window size (tokens) for the per-session meter, used
    /// only when a session doesn't carry an explicit `meta.context_window`
    /// (`SessionInfo.reportedContextWindow`, always preferred over this).
    /// User-editable specifically so a new model generation shipping a
    /// different window is a Settings edit, not a FocalPoint rebuild — the
    /// previous hardcoded-per-model-name guess (Protocol.swift) went stale
    /// the moment a current model exceeded it. nil turns the meter off
    /// entirely for sessions with no explicit report.
    @Published var contextWindowOverride: Int? {
        didSet {
            if let contextWindowOverride {
                UserDefaults.standard.set(contextWindowOverride, forKey: "contextWindowOverride")
            } else {
                UserDefaults.standard.removeObject(forKey: "contextWindowOverride")
            }
        }
    }

    // Wiring set by the app delegate.
    var onHotkeysToggled: ((Bool) -> Void)?
    var onHotkeyBindingsChanged: (([HotkeyActionID: HotkeyBinding]) -> Void)?

    let client = DaemonClient()
    private var timer: Timer?
    private var codexUsageMonitor: CodexUsageMonitor?
    private var cursorUsageMonitor: CursorUsageMonitor?
    /// Last session focused by the attention/session-nav hotkeys, so the next
    /// press can advance relative to it rather than always restarting at the
    /// front of the list. Deliberately not persisted or @Published — pure
    /// runtime bookkeeping, not user-facing state.
    private var lastAttentionFocusID: String?
    private var lastSessionFocusID: String?

    private init() {
        let d = UserDefaults.standard
        coloredIcon = d.object(forKey: "coloredIcon") as? Bool ?? false
        hotkeysEnabled = d.object(forKey: "hotkeysEnabled") as? Bool ?? true
        if let data = d.data(forKey: "hotkeyBindings"),
           let decoded = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) {
            hotkeyBindings = decoded
        } else {
            hotkeyBindings = [:]
        }
        if let raw = d.string(forKey: "desktopWidgetMode"), let mode = DesktopWidgetMode(rawValue: raw) {
            desktopWidgetMode = mode
        } else if let legacy = d.object(forKey: "showDesktopOverlay") as? Bool {
            // Migrate from the old plain bool toggle.
            desktopWidgetMode = legacy ? .always : .hidden
        } else {
            desktopWidgetMode = .always
        }
        interfaceTranslucency = d.object(forKey: "interfaceTranslucency") as? Double ?? 0.35
        if let raw = d.array(forKey: "visibleStats") as? [String] {
            visibleStats = Set(raw.compactMap(SessionStat.init(rawValue:)))
        } else {
            visibleStats = Set(SessionStat.allCases)
        }
        showUsage = d.object(forKey: "showUsage") as? Bool ?? true
        showModelBadge = d.object(forKey: "showModelBadge") as? Bool ?? true
        codexUsageEnabled = d.object(forKey: "codexUsageEnabled") as? Bool ?? false
        cursorUsageEnabled = d.object(forKey: "cursorUsageEnabled") as? Bool ?? true
        if let raw = d.string(forKey: "attentionCycleOrder"), let order = AttentionCycleOrder(rawValue: raw) {
            attentionCycleOrder = order
        } else {
            attentionCycleOrder = .severityFirst
        }
        tokenBudget = d.object(forKey: "tokenBudget") as? Int
        costBudget = d.object(forKey: "costBudget") as? Double
        staleThresholdMinutes = d.object(forKey: "staleThresholdMinutes") as? Int ?? 5
        // 967_000 seeds the same figure Protocol.swift used to hardcode
        // (Claude Code's own reported "Auto-compact window" for the current
        // model generation, verified live via /context) — same default
        // behavior on first run, but now a Settings edit away from staying
        // current instead of a rebuild.
        contextWindowOverride = d.object(forKey: "contextWindowOverride") as? Int ?? 967_000
        codexUsageMonitor = CodexUsageMonitor(model: self)
        cursorUsageMonitor = CursorUsageMonitor(model: self)
        if let data = d.data(forKey: "sessionHistory"),
           let decoded = try? JSONDecoder().decode([SessionHistoryEntry].self, from: data) {
            sessionHistory = decoded
        }
    }

    // MARK: - Derived

    /// Sessions that need user attention (waiting/error). Falls back to the
    /// aggregate when the daemon is aggregate-only (no session events).
    var attentionCount: Int {
        let n = sessions.filter { $0.state.needsAttention }.count
        if n > 0 { return n }
        if sessions.isEmpty && aggregate.needsAttention { return 1 }
        return 0
    }

    var aggregateStyle: StateStyle { styles[aggregate] ?? defaultStyle(aggregate) }

    /// True when `s` has crossed a configured budget threshold — either the
    /// token budget (tokens_in + tokens_out) or the cost budget (cost_usd),
    /// whichever is set. Either condition alone trips it; both being set
    /// doesn't require both to be crossed. Purely client-side (Settings →
    /// Agent Integrations → Budget alerts): mirrors `needsAttention` as a
    /// layered visual concept, not a real daemon state (see MenuContentView/
    /// DesktopOverlay `sessionRow`).
    func isOverBudget(_ s: SessionInfo) -> Bool {
        if let tokenBudget {
            let tokens = (s.stats[.tokensIn] ?? 0) + (s.stats[.tokensOut] ?? 0)
            if tokens >= Double(tokenBudget) { return true }
        }
        if let costBudget {
            let cost = s.stats[.cost] ?? 0
            if cost >= costBudget { return true }
        }
        return false
    }

    /// True when `s` claims to still be actively working (thinking/running/
    /// waiting) but hasn't been updated in at least `staleThresholdMinutes`.
    /// Idle/done/error sessions are excluded — those are already "at rest"
    /// states where sitting unchanged is normal, not a sign the agent died.
    /// Purely client-side and purely visual (see `sessionRow` in
    /// MenuContentView/DesktopOverlay, which dims the row and shows an idle
    /// look instead of the stale live state) — mirrors `isOverBudget` as a
    /// layered heuristic, not a real daemon state.
    func isStale(_ s: SessionInfo) -> Bool {
        guard let staleThresholdMinutes else { return false }
        guard [AgentState.thinking, .running, .waiting].contains(s.state) else { return false }
        return Date().timeIntervalSince(s.lastChange) >= Double(staleThresholdMinutes) * 60
    }

    /// Every action's effective binding: the user's override if present,
    /// else the shipped default. This is what HotkeyManager actually
    /// registers with Carbon.
    var resolvedHotkeyBindings: [HotkeyActionID: HotkeyBinding] {
        var result: [HotkeyActionID: HotkeyBinding] = [:]
        for action in HotkeyActionID.allCases {
            result[action] = hotkeyBindings[action.rawValue] ?? action.defaultBinding
        }
        return result
    }

    // MARK: - Lifecycle

    func start() {
        client.startSubscribe(
            onStatus: { up in
                Task { @MainActor in AppModel.shared.setConnected(up) }
            },
            onConnect: {
                Task { @MainActor in AppModel.shared.refreshOnConnect() }
            },
            onEvent: { obj in
                Task { @MainActor in AppModel.shared.handleEvent(obj) }
            }
        )
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { AppModel.shared.tick &+= 1 }
        }
        if codexUsageEnabled { codexUsageMonitor?.start() }
        if cursorUsageEnabled { cursorUsageMonitor?.start() }
    }

    private func setConnected(_ up: Bool) {
        connected = up
        if !up {
            // Daemon gone: clear live view but keep last-known styles for the editor.
            sessions = []
            aggregate = .idle
            usage = []
        }
    }

    /// On (re)connect, refresh styles and sessions via one-shot requests.
    /// Older daemons return "unknown cmd"; we detect that and use defaults.
    private func refreshOnConnect() {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let stylesResp = client.request(["cmd": "get-styles"])
            let sessResp = client.request(["cmd": "list-sessions"])
            let usageResp = client.request(["cmd": "get-usage"])
            Task { @MainActor in
                self.applyStylesResponse(stylesResp)
                self.applySessionsResponse(sessResp)
                self.applyUsageResponse(usageResp)
            }
        }
    }

    // MARK: - Event handling (PROTOCOL.md §3)

    private func handleEvent(_ e: [String: Any]) {
        guard let ev = e["event"] as? String else { return }
        if ProcessInfo.processInfo.environment["FOCALPOINT_DEBUG"] != nil {
            log("event: \(e)")
        }
        switch ev {
        case "state":
            if let s = e["state"] as? String, let st = AgentState(rawValue: s) {
                aggregate = st
            }
        case "session":
            upsertSession(e)
        case "session-ended":
            if let id = e["session"] as? String {
                recordSessionEnded(id)
                sessions.removeAll { $0.id == id }
                if focusedSessionID == id { focusedSessionID = nil }
            }
        case "session-rekeyed":
            // A `compacting` session was reunited with its post-compaction
            // continuation under a new session_id (PROTOCOL.md §3). Relabel
            // the existing record in place — preserving name/firstSeen/
            // stats — rather than treat it as an end; the `session` event
            // that immediately follows carries the continuation's actual
            // state and merges into this same record via `upsertSession`.
            if let oldID = e["old_session"] as? String,
               let newID = e["new_session"] as? String,
               let idx = sessions.firstIndex(where: { $0.id == oldID }) {
                sessions[idx].id = newID
                if focusedSessionID == oldID { focusedSessionID = newID }
            }
        case "usage":
            upsertUsage(e)
        case "style":
            if let s = e["state"] as? String, let st = AgentState(rawValue: s),
               let style = Self.parseStyle(e) {
                styles[st] = style
                stylesSupported = true
            }
        default:
            break   // key/dial/joy events are not surfaced in the UI
        }
    }

    private func upsertSession(_ e: [String: Any]) {
        guard let id = e["session"] as? String else { return }
        sessionsSupported = true
        let stateStr = e["state"] as? String ?? "idle"
        let newState = AgentState(rawValue: stateStr) ?? .idle
        let slot = e["slot"] as? Int
        let kind = e["kind"] as? String ?? "agent"
        let label = e["label"] as? String
        // Present but null once renamed and cleared; `as? String` yields nil
        // for both, which is exactly "no user name".
        let name = e["name"] as? String
        let meta = e["meta"] as? [String: Any]
        let cwd = meta?["cwd"] as? String
        let model = meta?["model"] as? String
        let contextTokens = (meta?["context_tokens"] as? NSNumber)?.doubleValue
        let reportedContextWindow = (meta?["context_window"] as? NSNumber)?.doubleValue
        let stats = Self.parseStats(meta)

        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            var s = sessions[idx]
            if s.state != newState { s.state = newState; s.lastChange = Date() }
            s.kind = kind
            if let label = label { s.label = label }
            // Assigned unconditionally, unlike label: a cleared rename comes
            // back as an explicit null, and the daemon always includes the
            // key, so nil genuinely means "no user name" (an older daemon
            // that omits it simply never has one).
            s.name = name
            if let slot = e["slot"] { s.slot = slot as? Int }
            if let cwd = cwd { s.cwd = cwd }
            if let model = model { s.model = model }
            if let contextTokens = contextTokens { s.contextTokens = contextTokens }
            if let reportedContextWindow = reportedContextWindow {
                s.reportedContextWindow = reportedContextWindow
            }
            if meta != nil { s.stats = stats }
            sessions[idx] = s
        } else {
            var s = SessionInfo(id: id, kind: kind, label: label, name: name,
                                 slot: slot, state: newState, cwd: cwd,
                                 firstSeen: Date(), lastChange: Date(), stats: stats)
            s.model = model
            s.contextTokens = contextTokens
            s.reportedContextWindow = reportedContextWindow
            sessions.append(s)
        }
        sortSessions()
    }

    private func sortSessions() {
        // Slot order; slotless sessions last (PROTOCOL.md §3 list-sessions).
        sessions.sort { a, b in
            switch (a.slot, b.slot) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return a.id < b.id
            }
        }
    }

    private func upsertUsage(_ event: [String: Any]) {
        guard let provider = event["provider"] as? String,
              let values = Self.parseUsage(event["usage"] as? [String: Any]) else { return }
        usageSupported = true
        let record = ProviderUsage(provider: provider, values: values, updatedAt: Date())
        if let index = usage.firstIndex(where: { $0.provider == provider }) {
            usage[index] = record
        } else {
            usage.append(record)
            usage.sort { $0.provider < $1.provider }
        }
    }

    // MARK: - One-shot response parsing

    private func applyStylesResponse(_ resp: [String: Any]?) {
        guard let resp = resp, (resp["ok"] as? Bool) == true,
              let arr = resp["styles"] as? [[String: Any]] else {
            // Unknown cmd / error / offline: keep defaults, mark unsupported.
            stylesSupported = false
            return
        }
        stylesSupported = true
        for item in arr {
            if let s = item["state"] as? String, let st = AgentState(rawValue: s),
               let style = Self.parseStyle(item) {
                styles[st] = style
            }
        }
    }

    private func applySessionsResponse(_ resp: [String: Any]?) {
        guard let resp = resp, (resp["ok"] as? Bool) == true,
              let arr = resp["sessions"] as? [[String: Any]] else { return }
        sessionsSupported = true
        var seen = Set<String>()
        for item in arr {
            var e = item
            e["session"] = item["session"]
            upsertSession(e)
            if let id = item["session"] as? String { seen.insert(id) }
        }
        // Drop any session no longer present.
        sessions.removeAll { !seen.contains($0.id) }
        sortSessions()
    }

    private func applyUsageResponse(_ response: [String: Any]?) {
        guard let response,
              (response["ok"] as? Bool) == true,
              let snapshots = response["usage"] as? [String: [String: Any]] else {
            usageSupported = false
            return
        }
        usageSupported = true
        usage = snapshots.compactMap { provider, snapshot in
            guard let values = Self.parseUsage(snapshot) else { return nil }
            return ProviderUsage(provider: provider, values: values, updatedAt: Date())
        }
        .sorted { $0.provider < $1.provider }
    }

    /// Well-known numeric meta keys (PROTOCOL.md §4) → SessionStat. Absent
    /// or non-numeric keys are simply skipped, so an adapter reporting only
    /// some stats (or none) never produces a placeholder/zero badge.
    static func parseStats(_ meta: [String: Any]?) -> [SessionStat: Double] {
        guard let meta else { return [:] }
        var result: [SessionStat: Double] = [:]
        for stat in SessionStat.allCases {
            if let n = meta[stat.rawValue] as? NSNumber {
                result[stat] = n.doubleValue
            }
        }
        return result
    }

    static func parseUsage(_ raw: [String: Any]?) -> [String: Double]? {
        guard let raw else { return nil }
        let values = raw.compactMapValues { ($0 as? NSNumber)?.doubleValue }
        return values.isEmpty ? nil : values
    }

    static func parseStyle(_ d: [String: Any]) -> StateStyle? {
        guard let rgbAny = d["rgb"] as? [Any] else { return nil }
        let rgb = rgbAny.compactMap { ($0 as? NSNumber)?.intValue }
        guard rgb.count == 3 else { return nil }
        let pattern = Pattern(rawValue: (d["pattern"] as? String) ?? "solid") ?? .solid
        let period = (d["period_ms"] as? NSNumber)?.intValue ?? 1000
        return StateStyle(rgb: rgb, pattern: pattern, periodMs: period)
    }

    // MARK: - Commands

    /// Focus/bounce a session by tapping its numbered key (PROTOCOL.md §3 Focus).
    func focusSession(_ s: SessionInfo) {
        guard let slot = s.slot else { return }
        focusedSessionID = s.id
        client.send(["cmd": "inject", "kind": "key", "control": "key\(slot)", "action": "tap"])
    }

    // MARK: - Focus-navigation hotkeys (attention-next/prev, session-next/prev)

    /// Sessions needing attention (waiting/error), ordered per
    /// `attentionCycleOrder`. Slotless sessions are excluded — there's no
    /// numbered key to tap for them.
    private var orderedAttentionSessions: [SessionInfo] {
        let candidates = sessions.filter { $0.state.needsAttention && $0.slot != nil }
        switch attentionCycleOrder {
        case .oldestFirst:
            return candidates.sorted { $0.lastChange < $1.lastChange }
        case .severityFirst:
            return candidates.sorted { a, b in
                if a.state != b.state { return a.state == .error }
                return a.lastChange < b.lastChange
            }
        }
    }

    /// Every focusable session in registration (slot) order — `sessions` is
    /// already kept sorted that way by `sortSessions()`.
    private var orderedAllSessions: [SessionInfo] {
        sessions.filter { $0.slot != nil }
    }

    func focusNextAttentionSession() { advanceFocus(in: orderedAttentionSessions, cursor: \.lastAttentionFocusID, delta: 1) }
    func focusPrevAttentionSession() { advanceFocus(in: orderedAttentionSessions, cursor: \.lastAttentionFocusID, delta: -1) }
    func focusNextSession() { advanceFocus(in: orderedAllSessions, cursor: \.lastSessionFocusID, delta: 1) }
    func focusPrevSession() { advanceFocus(in: orderedAllSessions, cursor: \.lastSessionFocusID, delta: -1) }

    /// Moves `delta` positions (wrapping) from whichever session the matching
    /// cursor last landed on, then focuses and records the result. If the
    /// cursor's session isn't in `list` anymore (resolved, ended, or reshuffled
    /// out by a reorder), restarts at the edge `delta` points at rather than
    /// picking an arbitrary spot.
    private func advanceFocus(in list: [SessionInfo], cursor: ReferenceWritableKeyPath<AppModel, String?>, delta: Int) {
        guard !list.isEmpty else { return }
        let next: SessionInfo
        if let id = self[keyPath: cursor], let idx = list.firstIndex(where: { $0.id == id }) {
            let count = list.count
            next = list[((idx + delta) % count + count) % count]
        } else {
            next = delta > 0 ? list[0] : list[list.count - 1]
        }
        self[keyPath: cursor] = next.id
        focusSession(next)
    }

    /// Rename a session (PROTOCOL.md §3). An empty/whitespace-only name
    /// clears the rename so the adapter's label shows again.
    ///
    /// Applied optimistically so the row updates the instant the user hits
    /// return; the daemon's `session` broadcast confirms it a moment later,
    /// and if the daemon is too old to know the command the row simply
    /// reverts on its next state change.
    func renameSession(_ s: SessionInfo, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[idx].name = trimmed.isEmpty ? nil : trimmed
        }
        client.send(["cmd": "rename-session",
                     "session": s.id,
                     "name": trimmed])
    }

    /// Manually end a session (PROTOCOL.md §3/§4) — a user-triggered escape
    /// hatch alongside the daemon's own automatic reaping (TTL, the dead-tty
    /// sweep, the Codex PID watcher). The `"session-ended"` broadcast that
    /// comes back removes it from `sessions` and records it in
    /// `sessionHistory` via the normal `handleEvent` path — no optimistic
    /// local removal here.
    func endSession(_ s: SessionInfo) {
        client.send(["cmd": "end-session", "session": s.id])
    }

    /// Manually swap two sessions' numbered-key slots — a user-initiated
    /// reorder (drag-and-drop in the dropdown), distinct from the daemon's
    /// automatic "lowest free slot, kept for life" assignment (PROTOCOL.md
    /// §3). Applied optimistically like `renameSession` for the same
    /// reason: instant visual feedback, confirmed a moment later by the
    /// `session` broadcasts the swap triggers. Both sessions must currently
    /// hold a slot — a slotless (>12 live) session has nothing to swap.
    func swapSlots(_ a: SessionInfo, _ b: SessionInfo) {
        guard a.id != b.id, let slotA = a.slot, let slotB = b.slot else { return }
        if let idxA = sessions.firstIndex(where: { $0.id == a.id }) {
            sessions[idxA].slot = slotB
        }
        if let idxB = sessions.firstIndex(where: { $0.id == b.id }) {
            sessions[idxB].slot = slotA
        }
        sortSessions()
        client.send(["cmd": "swap-slots", "session1": a.id, "session2": b.id])
    }

    /// Snapshots a session into `sessionHistory` right before it's dropped
    /// from `sessions` — called from the `"session-ended"` case, which fires
    /// for both an explicit `end-session` and TTL expiry (PROTOCOL.md §3).
    private func recordSessionEnded(_ id: String) {
        guard let s = sessions.first(where: { $0.id == id }) else { return }
        let entry = SessionHistoryEntry(
            id: UUID().uuidString, sessionID: s.id, title: s.title, kind: s.kind,
            cwd: s.cwd, finalState: s.state, startedAt: s.firstSeen, endedAt: Date(),
            statValues: Dictionary(uniqueKeysWithValues: s.stats.map { ($0.key.rawValue, $0.value) }))
        sessionHistory.insert(entry, at: 0)
        if sessionHistory.count > maxSessionHistoryEntries {
            sessionHistory.removeLast(sessionHistory.count - maxSessionHistoryEntries)
        }
    }

    func clearSessionHistory() {
        sessionHistory.removeAll()
    }

    // MARK: - Quick actions (session cwd)

    /// Opens a new Terminal window at `path`. Plain `NSWorkspace`, not
    /// `osascript` UI-scripting — the latter needs Accessibility access this
    /// app doesn't (and shouldn't have to) request.
    func openInTerminal(_ path: String) {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path, isDirectory: true)],
                                 withApplicationAt: terminalURL,
                                 configuration: NSWorkspace.OpenConfiguration())
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Send set-style for one state (debounced by the caller).
    func setStyle(_ state: AgentState, _ style: StateStyle) {
        styles[state] = style
        client.send(["cmd": "set-style",
                     "state": state.rawValue,
                     "rgb": style.rgb,
                     "pattern": style.pattern.rawValue,
                     "period_ms": style.periodMs])
    }

    func resetStyles() {
        for (state, style) in defaultStyles {
            setStyle(state, style)
        }
    }

    // MARK: - Hotkey bindings

    /// If `keyCode`+`modifiers` is already bound to a different action,
    /// returns that action so the recorder can warn (and refuse to save —
    /// see HotkeysSettingsView, which blocks rather than auto-swapping).
    func conflictingHotkeyAction(keyCode: UInt32, modifiers: UInt32,
                                  excluding: HotkeyActionID) -> HotkeyActionID? {
        for (action, binding) in resolvedHotkeyBindings where action != excluding {
            if binding.keyCode == keyCode && binding.modifiers == modifiers { return action }
        }
        return nil
    }

    func setHotkeyBinding(_ action: HotkeyActionID, keyCode: UInt32, modifiers: UInt32) {
        hotkeyBindings[action.rawValue] = HotkeyBinding(keyCode: keyCode, modifiers: modifiers)
    }

    /// Removing the override falls back to the shipped default via
    /// `resolvedHotkeyBindings` — no need to look the default up here.
    func resetHotkeyBinding(_ action: HotkeyActionID) {
        hotkeyBindings.removeValue(forKey: action.rawValue)
    }

    func resetAllHotkeyBindings() {
        hotkeyBindings = [:]
    }
}
