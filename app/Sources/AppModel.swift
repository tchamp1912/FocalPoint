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

/// Layout direction for the desktop widget. Vertical is the original tall
/// card (header on top, sessions stacked); horizontal is a minimal strip
/// rendering the pad itself — one state-lit keycap per session, details on
/// hover — that sits naturally along a screen's top/bottom edge.
enum DesktopWidgetOrientation: String, CaseIterable, Identifiable {
    case vertical
    case horizontal

    var id: String { rawValue }

    var display: String {
        switch self {
        case .vertical:   return "Vertical"
        case .horizontal: return "Horizontal"
        }
    }

    /// Guardrails for the corner-grip width resize. The min keeps the header
    /// plus one session legible; the max keeps the widget a HUD, not a
    /// window.
    var minWidgetWidth: CGFloat {
        switch self {
        case .vertical:   return 200
        case .horizontal: return 96   // key strip: mark + a couple of keys
        }
    }
    var maxWidgetWidth: CGFloat {
        switch self {
        case .vertical:   return 560
        case .horizontal: return 1600
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
    /// Tracks API-account telemetry from the moment this is enabled (or last
    /// reset). It is entirely local: provider billing periods are untouched.
    @Published var apiUsageTrackingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(apiUsageTrackingEnabled, forKey: "apiUsageTrackingEnabled")
            if apiUsageTrackingEnabled && !oldValue { resetAPIUsageTracking() }
        }
    }
    @Published private(set) var apiUsageTrackingResetAt: Date?
    private var apiUsageBaselines: [String: [String: Double]] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(apiUsageBaselines) {
                UserDefaults.standard.set(data, forKey: "apiUsageBaselines")
            }
        }
    }
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
    /// Explicit live-session promotions waiting for the daemon's
    /// `session-ended` event. A process cannot be adopted into tmux, so the
    /// handoff is necessarily quit first, then resume under the managed
    /// launcher. Runtime-only: a failed app relaunch must never surprise the
    /// user by resuming an old conversation later.
    private var pendingManagedRelaunch: Set<String> = []
    private var attachedManagedRelaunches: Set<String> = []
    /// User-visible state for the most recently requested managed relaunch.
    /// Progress is replaced by a terminal success/error until dismissed.
    @Published private(set) var managedRelaunchStatus: ManagedRelaunchStatus?
    /// The session FocalPoint itself last told to come forward — via a row
    /// click, a `key1`–`9` hotkey, or an all-session navigation hotkey (see
    /// `focusSession`). Attention navigation is resolved inside the daemon,
    /// so it clears this value rather than guessing the daemon's cursor.
    /// Best-effort, not a true "frontmost window" signal:
    /// the daemon has no concept of focus (Focus is a one-shot bounce, per
    /// PROTOCOL.md §3), and this can't see focus changes made outside
    /// FocalPoint (e.g. manually clicking a different terminal). Runtime-only,
    /// not persisted — a fresh launch has no known focus.
    @Published var focusedSessionID: String?
    /// Session priority as owned by focalpointd, highest priority first.
    /// This is presentation state only: the daemon also resolves and focuses
    /// the next/previous session, so every controller follows one cursor and
    /// one ordering decision.
    @Published private(set) var attentionOrder: [String] = []

    // Styles
    @Published var styles: [AgentState: StateStyle] = defaultStyles
    @Published var stylesSupported = false       // daemon knows get-styles/set-style

    // A monotonically increasing tick to refresh relative times once a second.
    @Published var tick = 0

    // Settings (persisted)
    @Published var coloredIcon: Bool {
        didSet { UserDefaults.standard.set(coloredIcon, forKey: "coloredIcon") }
    }
    /// Bundle id of the terminal app used to launch sessions ("Open in
    /// Terminal", History → Resume). Empty string = the system default handler
    /// for the target (its "Open With" default). Defaults to Terminal.app.
    @Published var terminalBundleID: String {
        didSet { UserDefaults.standard.set(terminalBundleID, forKey: "terminalBundleID") }
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
    /// Desktop widget layout direction (vertical card vs. horizontal strip).
    @Published var desktopWidgetOrientation: DesktopWidgetOrientation {
        didSet {
            UserDefaults.standard.set(desktopWidgetOrientation.rawValue,
                                      forKey: "desktopWidgetOrientation")
        }
    }
    /// User-chosen widget width from the corner resize grip, per
    /// orientation. nil = automatic (fixed 260pt for vertical, content-
    /// fitted for horizontal). Height is always content-fitted — pinning it
    /// fought the widget's reason to exist: sessions appearing/disappearing
    /// reshaped a pinned frame into dead space or clipped rows, and the
    /// bottom-left-anchored AppKit refit made the widget visibly jump.
    @Published private(set) var widgetWidthVertical: CGFloat?
    @Published private(set) var widgetWidthHorizontal: CGFloat?
    /// One-line session rows in the desktop widget (hides the per-row stats
    /// badges and the context meter). Widget-only: the dropdown keeps its
    /// full rows, since it has the room.
    @Published var compactWidgetRows: Bool {
        didSet { UserDefaults.standard.set(compactWidgetRows, forKey: "compactWidgetRows") }
    }
    /// Runtime-only override toggled by the "Toggle Widget" hotkey — hides
    /// the widget on demand without touching the persisted `desktopWidgetMode`
    /// setting. Deliberately not persisted: it resets on relaunch so the
    /// configured mode is what you get back.
    @Published var desktopWidgetHotkeyHidden = false
    /// Desktop widget frosted-background opacity (1.0 = opaque, lower =
    /// more see-through). Settings uses a fixed high opacity instead — see
    /// Metrics.settingsPaneOpacity.
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
    /// active-looking state (thinking/running/waiting/approval) is treated as
    /// probably-stale — almost always because the underlying agent process
    /// died without a clean Stop/SessionEnd (crash, killed terminal, sleep)
    /// rather than because it's genuinely still working that long. nil turns
    /// this off. This is intentionally UI-only: the daemon never removes a
    /// session merely because it has not updated.
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
    /// Per-adapter context-window cap for the session meter (Settings → Agent
    /// Integrations). When set, takes precedence over the adapter-reported
    /// `context_window` so you can align the bar with your own compact/rot
    /// threshold. Blank for a provider uses its reported window when available.
    @Published var contextWindowByKind: [String: Int] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(contextWindowByKind) {
                UserDefaults.standard.set(data, forKey: "contextWindowByKind")
            }
        }
    }

    /// Resolved context-window override for a session `kind` (e.g. claude/codex).
    func contextWindowOverride(for kind: String) -> Int? {
        contextWindowByKind[kind.lowercased()]
    }

    // MARK: Widget width overrides (corner-grip resize)

    func widgetWidth(for orientation: DesktopWidgetOrientation) -> CGFloat? {
        switch orientation {
        case .vertical:   return widgetWidthVertical
        case .horizontal: return widgetWidthHorizontal
        }
    }

    func setWidgetWidth(_ width: CGFloat, for orientation: DesktopWidgetOrientation) {
        previewWidgetWidth(width, for: orientation)
        guard let clamped = widgetWidth(for: orientation) else { return }
        UserDefaults.standard.set(Double(clamped), forKey: Self.widgetWidthKey(for: orientation))
    }

    /// Live grip-drag updates: in-memory only (the UserDefaults write waits
    /// for mouse-up in setWidgetWidth). Keeping the root SwiftUI frame in
    /// lockstep with the dragged window frame prevents the clear-background
    /// window from showing a gap between content and window edge mid-drag.
    func previewWidgetWidth(_ width: CGFloat, for orientation: DesktopWidgetOrientation) {
        let clamped = min(max(width, orientation.minWidgetWidth), orientation.maxWidgetWidth)
        switch orientation {
        case .vertical:   widgetWidthVertical = clamped
        case .horizontal: widgetWidthHorizontal = clamped
        }
    }

    /// Back to automatic width for this orientation.
    func resetWidgetWidth(for orientation: DesktopWidgetOrientation) {
        switch orientation {
        case .vertical:   widgetWidthVertical = nil
        case .horizontal: widgetWidthHorizontal = nil
        }
        UserDefaults.standard.removeObject(forKey: Self.widgetWidthKey(for: orientation))
    }

    private static func widgetWidthKey(for orientation: DesktopWidgetOrientation) -> String {
        switch orientation {
        case .vertical:   return "desktopWidgetWidthV"
        case .horizontal: return "desktopWidgetWidthH"
        }
    }

    private static func loadWidgetWidth(for orientation: DesktopWidgetOrientation) -> CGFloat? {
        let d = UserDefaults.standard
        let key = widgetWidthKey(for: orientation)
        // object(forKey:) (not double(forKey:)) so "never resized" is
        // distinguishable from a stored 0, which would be invalid anyway.
        guard d.object(forKey: key) != nil else { return nil }
        let width = CGFloat(d.double(forKey: key))
        return width >= orientation.minWidgetWidth ? width : nil
    }

    // Wiring set by the app delegate.
    var onHotkeysToggled: ((Bool) -> Void)?
    var onHotkeyBindingsChanged: (([HotkeyActionID: HotkeyBinding]) -> Void)?

    let client = DaemonClient()
    private var timer: Timer?
    private var codexUsageMonitor: CodexUsageMonitor?
    private var cursorUsageMonitor: CursorUsageMonitor?
    private var claudeUsageMonitor: ClaudeUsageMonitor?
    /// Last session focused by the all-session navigation hotkeys, so the next
    /// press advances relative to it. Attention navigation is daemon-owned.
    private var lastSessionFocusID: String?
    /// Non-nil while focalpointd is delivering an authoritative reconnect
    /// snapshot. The generation pairs begin/end markers and lets a malformed
    /// or interrupted snapshot be discarded by the subsequent reconnect.
    private var activeSnapshotGeneration: UInt64?

    private init() {
        let d = UserDefaults.standard
        coloredIcon = d.object(forKey: "coloredIcon") as? Bool ?? false
        terminalBundleID = d.string(forKey: "terminalBundleID") ?? "com.apple.Terminal"
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
        desktopWidgetOrientation = DesktopWidgetOrientation(
            rawValue: d.string(forKey: "desktopWidgetOrientation") ?? "") ?? .vertical
        widgetWidthVertical = Self.loadWidgetWidth(for: .vertical)
        widgetWidthHorizontal = Self.loadWidgetWidth(for: .horizontal)
        compactWidgetRows = d.object(forKey: "compactWidgetRows") as? Bool ?? false
        interfaceTranslucency = d.object(forKey: "interfaceTranslucency") as? Double ?? 0.35
        if let raw = d.array(forKey: "visibleStats") as? [String] {
            visibleStats = Set(raw.compactMap(SessionStat.init(rawValue:)))
        } else {
            visibleStats = Set(SessionStat.allCases)
        }
        showUsage = d.object(forKey: "showUsage") as? Bool ?? true
        apiUsageTrackingEnabled = d.object(forKey: "apiUsageTrackingEnabled") as? Bool ?? false
        apiUsageTrackingResetAt = d.object(forKey: "apiUsageTrackingResetAt") as? Date
        if let data = d.data(forKey: "apiUsageBaselines"),
           let decoded = try? JSONDecoder().decode([String: [String: Double]].self, from: data) {
            apiUsageBaselines = decoded
        }
        showModelBadge = d.object(forKey: "showModelBadge") as? Bool ?? true
        codexUsageEnabled = d.object(forKey: "codexUsageEnabled") as? Bool ?? false
        cursorUsageEnabled = d.object(forKey: "cursorUsageEnabled") as? Bool ?? true
        tokenBudget = d.object(forKey: "tokenBudget") as? Int
        costBudget = d.object(forKey: "costBudget") as? Double
        staleThresholdMinutes = d.object(forKey: "staleThresholdMinutes") as? Int ?? 5
        if let data = d.data(forKey: "contextWindowByKind"),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            contextWindowByKind = decoded
        } else {
            // Migrate the old single global override into a Claude default.
            let legacy = d.object(forKey: "contextWindowOverride") as? Int ?? 967_000
            contextWindowByKind = ["claude": legacy]
        }
        codexUsageMonitor = CodexUsageMonitor(model: self)
        cursorUsageMonitor = CursorUsageMonitor(model: self)
        claudeUsageMonitor = ClaudeUsageMonitor(model: self)
        if let data = d.data(forKey: "sessionHistory"),
           let decoded = try? JSONDecoder().decode([SessionHistoryEntry].self, from: data) {
            sessionHistory = decoded
        }
    }

    // MARK: - Derived

    /// Sessions that need user attention (waiting/approval/error). Falls back to the
    /// aggregate when the daemon is aggregate-only (no session events).
    /// Backlogged sessions are excluded to match the daemon's attention
    /// routing, which parked sessions leave (PROTOCOL.md §3).
    var attentionCount: Int {
        let n = sessions.filter { $0.state.needsAttention && !$0.backlogged }.count
        if n > 0 { return n }
        if sessions.isEmpty && aggregate.needsAttention { return 1 }
        return 0
    }

    /// Starts a fresh local accounting interval at the latest provider values.
    /// This never changes remote billing, rate limits, or daemon snapshots.
    func resetAPIUsageTracking() {
        apiUsageBaselines = Dictionary(uniqueKeysWithValues: usage
            .filter { $0.isAPIAccount }
            .map { ($0.provider, $0.values) })
        apiUsageTrackingResetAt = Date()
        UserDefaults.standard.set(apiUsageTrackingResetAt, forKey: "apiUsageTrackingResetAt")
    }

    func trackedAPISpend(for record: ProviderUsage) -> Double? {
        trackedAPIValue("api_spend_usd", for: record)
    }

    func trackedAPIInputTokens(for record: ProviderUsage) -> Double? {
        trackedAPIValue("api_input_tokens", for: record)
    }

    func trackedAPIOutputTokens(for record: ProviderUsage) -> Double? {
        trackedAPIValue("api_output_tokens", for: record)
    }

    var apiUsageTrackingLabel: String {
        apiUsageTrackingEnabled ? "since reset" : "this provider period"
    }

    private func trackedAPIValue(_ key: String, for record: ProviderUsage) -> Double? {
        guard let current = record.values[key] else { return nil }
        guard apiUsageTrackingEnabled else { return current }
        let baseline = apiUsageBaselines[record.provider]?[key] ?? current
        return max(0, current - baseline)
    }

    private func captureAPIUsageBaselineIfNeeded(for record: ProviderUsage) {
        guard apiUsageTrackingEnabled, record.isAPIAccount,
              apiUsageBaselines[record.provider] == nil else { return }
        apiUsageBaselines[record.provider] = record.values
        if apiUsageTrackingResetAt == nil {
            apiUsageTrackingResetAt = Date()
            UserDefaults.standard.set(apiUsageTrackingResetAt, forKey: "apiUsageTrackingResetAt")
        }
    }

    /// The highest-priority eligible row. The daemon owns the independent
    /// next/previous cycling cursor; this value is only the widget highlight.
    var highlightedAttentionSessionID: String? {
        attentionOrder.first { id in
            sessions.contains {
                $0.id == id && $0.connected && !$0.pendingReopen
                    && $0.state.needsAttention
            }
        }
    }

    func isNextAttentionSession(_ session: SessionInfo) -> Bool {
        session.id == highlightedAttentionSessionID
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
    /// waiting/approval) but hasn't been updated in at least `staleThresholdMinutes`.
    /// Idle/done/error sessions are excluded — those are already "at rest"
    /// states where sitting unchanged is normal, not a sign the agent died.
    /// Purely client-side and purely visual (see `sessionRow` in
    /// MenuContentView/DesktopOverlay, which dims the row and shows an idle
    /// look instead of the stale live state) — mirrors `isOverBudget` as a
    /// layered heuristic, not a real daemon state.
    func isStale(_ s: SessionInfo) -> Bool {
        guard let staleThresholdMinutes else { return false }
        guard [AgentState.thinking, .running, .waiting, .approval].contains(s.state) else { return false }
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
        log("app model start socket=\(focalpointSocketPath())")
        client.startSubscribe(
            onStatus: { up in
                Task { @MainActor in AppModel.shared.setConnected(up) }
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
        // This monitor is a no-op unless ANTHROPIC_ADMIN_KEY is present. Keep
        // it independent of the Claude Code status-line integration: API
        // billing telemetry and subscription rate limits are different data.
        claudeUsageMonitor?.start()
    }

    private func setConnected(_ up: Bool) {
        let previous = connected
        connected = up
        log("daemon status previous=\(previous) connected=\(up) rows=\(sessions.count)")
        if !up {
            // Daemon gone: clear live view but keep last-known styles for the editor.
            sessions = []
            aggregate = .idle
            usage = []
            attentionOrder = []
            activeSnapshotGeneration = nil
        }
    }

    // MARK: - Event handling (PROTOCOL.md §3)

    private func handleEvent(_ e: [String: Any]) {
        guard let ev = e["event"] as? String else { return }
        if ["state", "session", "session-ended", "session-disconnected",
            "session-rekeyed", "managed-relaunch", "attention-order", "focus"].contains(ev) {
            logEventSummary(e, event: ev)
        }
        switch ev {
        case "snapshot-begin":
            guard let generation = (e["generation"] as? NSNumber)?.uint64Value else { return }
            activeSnapshotGeneration = generation
            // The daemon closes a lagged stream instead of attempting to
            // continue with missing deltas, so every begin marker is a full
            // replacement. Clear collections that may legitimately be empty;
            // styles remain last-known until their eight replacement events
            // arrive immediately below this marker.
            sessions = []
            usage = []
            attentionOrder = []
            aggregate = .idle
            sessionsSupported = true
            usageSupported = true
            stylesSupported = true
            log("snapshot begin generation=\(generation)")
        case "snapshot-end":
            guard let generation = (e["generation"] as? NSNumber)?.uint64Value,
                  activeSnapshotGeneration == generation else {
                log("snapshot end ignored reason=generation-mismatch")
                return
            }
            activeSnapshotGeneration = nil
            log("snapshot complete generation=\(generation) rows=\(sessions.count) usage=\(usage.count)")
        case "state":
            if let s = e["state"] as? String, let st = AgentState(rawValue: s) {
                aggregate = st
            }
        case "session":
            upsertSession(e)
        case "session-ended":
            if let id = e["session"] as? String {
                let previous = sessions.first(where: { $0.id == id })
                log("row remove event=session-ended id=\(boundedLogField(id)) existed=\(previous != nil) slot=\(previous?.slot.map(String.init) ?? "-") state=\(previous?.state.rawValue ?? "-") connected=\(previous?.connected.description ?? "-") managed=\(previous?.managed.description ?? "-")")
                recordSessionEnded(id)
                sessions.removeAll { $0.id == id }
                if focusedSessionID == id { focusedSessionID = nil }
            }
        case "session-disconnected":
            // A sweep reaped the session (PROTOCOL.md §3). Unlike
            // `session-ended`, keep the row — just mark it disconnected so it
            // renders dimmed with the disconnected glyph. It stays until it's
            // explicitly ended, dismissed, reconnects, or its tombstone TTL
            // expires. A reconnect arrives as a normal `session` event, which
            // flips `connected` back to true via `upsertSession`.
            if let id = e["session"] as? String,
               let idx = sessions.firstIndex(where: { $0.id == id }) {
                log("row disconnect id=\(boundedLogField(id)) slot=\(sessions[idx].slot.map(String.init) ?? "-") state=\(sessions[idx].state.rawValue)")
                sessions[idx].connected = false
                if focusedSessionID == id { focusedSessionID = nil }
                sortSessions()
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
                log("row rekey old=\(boundedLogField(oldID)) new=\(boundedLogField(newID)) slot=\(sessions[idx].slot.map(String.init) ?? "-")")
                sessions[idx].id = newID
                if pendingManagedRelaunch.remove(oldID) != nil {
                    pendingManagedRelaunch.insert(newID)
                }
                if managedRelaunchStatus?.sessionID == oldID {
                    managedRelaunchStatus?.sessionID = newID
                }
                if focusedSessionID == oldID { focusedSessionID = newID }
            }
        case "managed-relaunch":
            handleManagedRelaunchEvent(e)
        case "attention-order":
            applyAttentionOrder(e["sessions"], source: "event")
        case "focus":
            if let id = e["session"] as? String {
                focusedSessionID = id
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

    /// Log only the protocol fields needed to reconstruct row identity and
    /// routing. Deliberately do not serialize the event or its full `meta`.
    private func logEventSummary(_ event: [String: Any], event name: String) {
        let meta = event["meta"] as? [String: Any]
        log("event=\(boundedLogField(name)) id=\(boundedLogField(event["session"])) state=\(boundedLogField(event["state"])) slot=\(boundedLogField(event["slot"])) kind=\(boundedLogField(event["kind"])) title=\(boundedLogField(event["label"])) task_id=\(boundedLogField(meta?["orchestrator_task_id"])) role=\(boundedLogField(meta?["orchestration_role"])) manager=\(boundedLogField(meta?["manager_task_id"])) pid=\(boundedLogField(meta?["pid"])) tty=\(boundedLogField(meta?["tty"])) mux_server=\(boundedLogField(meta?["mux_server"])) mux_session=\(boundedLogField(meta?["mux_session"])) mux_pane=\(boundedLogField(meta?["mux_pane"])) managed=\(boundedLogField(meta?["managed"])) reregistered=\(boundedLogField(meta?["reregistered"])) old=\(boundedLogField(event["old_session"])) new=\(boundedLogField(event["new_session"])) status=\(boundedLogField(event["status"])) launch=\(boundedLogField(event["launch_id"]))")
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
        let managed = Self.parseManaged(meta?["managed"])
        let orchestratorTaskID = meta?["orchestrator_task_id"] as? String
        let orchestrationRole = meta?["orchestration_role"] as? String
        let managerTaskID = meta?["manager_task_id"] as? String
        let stats = Self.parseStats(meta)
        // A live `session` event carries no `connected` key and means the
        // session is active — default true. `list-sessions` includes the flag
        // explicitly (false for tombstoned/disconnected rows).
        let connected = e["connected"] as? Bool ?? true
        // Always present on a backlog-aware daemon (session events and
        // list-sessions); omitted by older daemons, where the feature is
        // simply absent.
        let backlogged = e["backlogged"] as? Bool ?? false

        let operation: String
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            operation = "update"
            var s = sessions[idx]
            if s.state != newState { s.state = newState; s.lastChange = Date() }
            s.connected = connected
            // A live managed relaunch is correlated by the daemon. Late
            // events from the old provider must not clear its pending state;
            // only the matching replacement's managed registration does.
            if !pendingManagedRelaunch.contains(id) || managed == true {
                s.pendingReopen = false
            }
            s.kind = kind
            if let label = label { s.label = label }
            // Assigned unconditionally, unlike label: a cleared rename comes
            // back as an explicit null, and the daemon always includes the
            // key, so nil genuinely means "no user name" (an older daemon
            // that omits it simply never has one).
            s.name = name
            if let slot = e["slot"] { s.slot = slot as? Int }
            if let b = e["backlogged"] as? Bool { s.backlogged = b }
            if let cwd = cwd { s.cwd = cwd }
            if let model = model { s.model = model }
            if let contextTokens = contextTokens { s.contextTokens = contextTokens }
            if let reportedContextWindow = reportedContextWindow {
                s.reportedContextWindow = reportedContextWindow
            }
            // Like model/cwd: only overwrite when this event's meta actually
            // carries the key, so a later event with a slimmer meta doesn't
            // clobber a managed session back to false.
            if let managed = managed { s.managed = managed }
            if let orchestratorTaskID { s.orchestratorTaskID = orchestratorTaskID }
            if let orchestrationRole { s.orchestrationRole = orchestrationRole }
            if let managerTaskID { s.managerTaskID = managerTaskID }
            if meta != nil { s.stats = stats }
            sessions[idx] = s
        } else {
            operation = "insert"
            var s = SessionInfo(id: id, kind: kind, label: label, name: name,
                                 slot: slot, state: newState, connected: connected,
                                 cwd: cwd,
                                 firstSeen: Date(), lastChange: Date(), stats: stats)
            s.model = model
            s.contextTokens = contextTokens
            s.reportedContextWindow = reportedContextWindow
            if let managed = managed { s.managed = managed }
            s.orchestratorTaskID = orchestratorTaskID
            s.orchestrationRole = orchestrationRole
            s.managerTaskID = managerTaskID
            s.backlogged = backlogged
            sessions.append(s)
        }
        log("row \(operation) id=\(boundedLogField(id)) title=\(boundedLogField(label)) task_id=\(boundedLogField(orchestratorTaskID)) slot=\(slot.map(String.init) ?? "-") requested_slot=\(boundedLogField(meta?["requested_slot"])) state=\(newState.rawValue) connected=\(connected) managed=\(managed.map(String.init) ?? "-") role=\(boundedLogField(orchestrationRole)) manager=\(boundedLogField(managerTaskID)) pid=\(boundedLogField(meta?["pid"])) tty=\(boundedLogField(meta?["tty"])) mux_server=\(boundedLogField(meta?["mux_server"])) mux_session=\(boundedLogField(meta?["mux_session"])) mux_pane=\(boundedLogField(meta?["mux_pane"])) reregistered=\(boundedLogField(meta?["reregistered"]))")
        sortSessions()
    }

    private func sortSessions() {
        // Connected first, then slot order; slotless sessions last
        // (PROTOCOL.md §3 list-sessions). Disconnected (tombstoned) sessions
        // sink below every live one so the active work stays at the top.
        sessions.sort { a, b in
            if a.connected != b.connected { return a.connected }
            switch (a.slot, b.slot) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return a.id < b.id
            }
        }
    }

    /// Rows use the canonical daemon slot order everywhere.  We used to lift
    /// orchestrators ahead of worker sessions here, which meant the menu and
    /// desktop widget could show (for example) slot 4 above slot 1 even while
    /// the keyboard correctly navigated slot 1 first.  Keep the projection as
    /// a named compatibility surface, but do not introduce a second order.
    var elevatedSessions: [SessionInfo] {
        sessions
    }

    /// The two presentation partitions of `sessions` (PROTOCOL.md §3
    /// backlog): the active list drives the aggregate/attention routing and
    /// holds the numbered slots; the backlog is parked-but-still-live work
    /// shown in its own section. `sessions` is already kept in daemon slot
    /// order by `sortSessions()`, so both filters inherit that order.
    var activeSessions: [SessionInfo] { sessions.filter { !$0.backlogged } }
    var backlogSessions: [SessionInfo] { sessions.filter(\.backlogged) }

    /// Park a live session in the backlog (or bring it back to active). The
    /// daemon keeps it registered and focusable by id, but it releases its
    /// numbered key (remaining slots compact to stay contiguous) and drops
    /// out of the aggregate and attention routing. No optimistic echo: the
    /// move also re-slots other sessions, and all of it arrives as `session`
    /// broadcasts a moment later over the local socket.
    func setSessionBacklogged(_ s: SessionInfo, _ backlogged: Bool) {
        client.send(["cmd": "set-session-backlogged", "session": s.id, "backlogged": backlogged])
    }

    var orchestratorSessions: [SessionInfo] { sessions.filter(\.isOrchestrator) }

    func orchestratorNumber(for session: SessionInfo) -> Int? {
        guard session.isOrchestrator else { return nil }
        return orchestratorSessions.firstIndex(where: { $0.id == session.id }).map { $0 + 1 }
    }

    func managingOrchestrator(for session: SessionInfo) -> SessionInfo? {
        guard let managerTaskID = session.managerTaskID else { return nil }
        return orchestratorSessions.first { $0.orchestratorTaskID == managerTaskID }
    }

    func managingOrchestratorNumber(for session: SessionInfo) -> Int? {
        managingOrchestrator(for: session).flatMap { orchestratorNumber(for: $0) }
    }

    func managedSessionCount(for orchestrator: SessionInfo) -> Int {
        guard let taskID = orchestrator.orchestratorTaskID else { return 0 }
        return sessions.lazy.filter { $0.managerTaskID == taskID }.count
    }

    private func upsertUsage(_ event: [String: Any]) {
        guard let provider = event["provider"] as? String,
              let values = Self.parseUsage(event["usage"] as? [String: Any]) else { return }
        usageSupported = true
        let record = ProviderUsage(provider: provider, values: values, updatedAt: Date())
        captureAPIUsageBaselineIfNeeded(for: record)
        if let index = usage.firstIndex(where: { $0.provider == provider }) {
            usage[index] = record
        } else {
            usage.append(record)
            usage.sort { $0.provider < $1.provider }
        }
    }

    /// Accept only a bounded, unique list of non-empty IDs. This keeps a
    /// malformed peer from driving unbounded UI/log work and avoids logging
    /// arbitrary response fields.
    private func applyAttentionOrder(_ raw: Any?, source: String) {
        guard let values = raw as? [Any], values.count <= 1_024 else {
            log("attention order rejected source=\(source) reason=shape-or-count")
            return
        }
        var order: [String] = []
        var seen = Set<String>()
        order.reserveCapacity(values.count)
        for value in values {
            guard let id = value as? String, !id.isEmpty, id.count <= 512,
                  seen.insert(id).inserted else {
                log("attention order rejected source=\(source) reason=invalid-id")
                return
            }
            order.append(id)
        }
        attentionOrder = order
        let preview = order.prefix(12).map { boundedLogField($0, limit: 80) }.joined(separator: ",")
        log("attention order applied source=\(source) count=\(order.count) ids=[\(preview)]")
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

    /// Parses `meta.managed` (PROTOCOL.md §4: meta values may be string or
    /// number — there's no wire-level boolean) into a `Bool?`. Accepts a JSON
    /// boolean/`NSNumber`, or the strings adapters actually shell out (e.g.
    /// `--meta managed=true`), including a bare "1"/"0". Returns nil when the
    /// key is absent or unrecognized, so callers can distinguish "not present
    /// in this event" from "present and false" — see the `upsertSession`
    /// callers, which only assign when non-nil (mirrors how `model`/`cwd` are
    /// merged: a slimmer follow-up event shouldn't clobber the last-known value).
    static func parseManaged(_ raw: Any?) -> Bool? {
        guard let raw else { return nil }
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            switch s.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
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
        focusedSessionID = s.id
        log("focus requested id=\(boundedLogField(s.id)) slot=\(s.slot.map(String.init) ?? "-") state=\(s.state.rawValue) connected=\(s.connected) managed=\(s.managed)")
        if s.connected, let slot = s.slot {
            // Live session with a slot: same path a numbered-key press takes.
            client.send(["cmd": "inject", "kind": "key", "control": "key\(slot)", "action": "tap"])
        } else {
            // Disconnected (or slotless) — focus by id. The daemon looks the
            // session up in live sessions or tombstones and runs the focus
            // action against its last-known tty/cwd. A reaped session's
            // terminal is usually still open (idle past the TTL, or an agent
            // crash that left the window), so trying to switch to it is worth
            // it even though it's no longer reporting.
            client.send(["cmd": "focus-session", "session": s.id])
        }
    }

    // MARK: - Focus-navigation hotkeys (attention-next/prev, session-next/prev)

    /// Every focusable session in registration (slot) order — `sessions` is
    /// already kept sorted that way by `sortSessions()`.
    private var orderedAllSessions: [SessionInfo] {
        sessions.filter { $0.connected && $0.slot != nil }
    }

    func focusNextAttentionSession() {
        log("attention focus requested direction=next priority_head=\(boundedLogField(highlightedAttentionSessionID)) order_count=\(attentionOrder.count)")
        focusedSessionID = nil
        client.send(["cmd": "focus-next-attention"])
    }

    func focusPrevAttentionSession() {
        log("attention focus requested direction=previous priority_head=\(boundedLogField(highlightedAttentionSessionID)) order_count=\(attentionOrder.count)")
        focusedSessionID = nil
        client.send(["cmd": "focus-prev-attention"])
    }
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

    /// Remove a session from FocalPoint **without** touching the agent — the
    /// non-destructive action ("Remove Session"). The agent keeps running; it
    /// just drops out of FocalPoint's list. The `"session-ended"` broadcast
    /// that comes back removes it from `sessions` and records it in
    /// `sessionHistory` via the normal `handleEvent` path — no optimistic
    /// local removal here. Also the "dismiss" action for a disconnected row.
    func removeSession(_ s: SessionInfo) {
        client.send(["cmd": "end-session", "session": s.id])
    }

    /// End a session **destructively** ("End Session"): ask the actual agent
    /// process to exit gracefully (the daemon sends SIGINT→SIGTERM, so the
    /// tool runs its own teardown and its SessionEnd hook fires — the same
    /// path as pressing Ctrl-C / typing `/exit`), then remove it. Use when
    /// you want the agent itself stopped, not just hidden. Falls back to a
    /// plain remove for a session with no resolved pid (Cursor, or one whose
    /// identity never resolved). An older daemon that doesn't know
    /// `quit-session` simply ignores it — pair it with the visible "Remove
    /// Session" action, which always works.
    func quitSession(_ s: SessionInfo) {
        client.send(["cmd": "quit-session", "session": s.id])
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

    /// Move a live session onto a specific free numbered slot (user-initiated
    /// sparse placement — PROTOCOL.md §3 move-slot). Companion to
    /// `swapSlots`, which exchanges two occupied slots. Optimistic for the
    /// same reason: the daemon's `session` broadcast confirms a moment later
    /// and is the correction if a race made the slot non-free.
    func moveSessionToSlot(_ s: SessionInfo, slot: Int) {
        guard s.slot != slot else { return }
        if let idx = sessions.firstIndex(where: { $0.id == s.id }) {
            sessions[idx].slot = slot
        }
        sortSessions()
        client.send(["cmd": "move-slot", "session": s.id, "slot": slot])
    }

    /// Numbered slots not held by any live, active session — the destinations
    /// Move to Slot offers. A disconnected row's last-held slot counts as
    /// free: it reports that slot but no longer occupies it (PROTOCOL.md §3).
    var freeSlots: [Int] {
        let used = Set(sessions.compactMap { $0.connected && !$0.backlogged ? $0.slot : nil })
        return (1...12).filter { !used.contains($0) }
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

    /// Well-known terminal apps, in menu order. Only those actually installed
    /// are offered in Settings (`installedTerminalApps`). VS Code opens a
    /// folder but not a `.command`, so it's fine for "Open in Terminal" but
    /// not Resume — an accepted limitation of a free-form app choice.
    static let knownTerminals: [(id: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("org.alacritty", "Alacritty"),
    ]

    /// The installed subset of `knownTerminals`, for the Settings picker.
    var installedTerminalApps: [(id: String, name: String)] {
        Self.knownTerminals.filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil
        }
    }

    /// Display name for the currently-selected terminal (for the picker /
    /// buttons). Falls back to the raw bundle id for a hand-picked app that
    /// isn't in `knownTerminals`.
    var terminalDisplayName: String {
        if terminalBundleID.isEmpty { return "System default" }
        if let known = Self.knownTerminals.first(where: { $0.id == terminalBundleID }) {
            return known.name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID) {
            return url.deletingPathExtension().lastPathComponent
        }
        return terminalBundleID
    }

    /// Resolved URL of the preferred terminal app, or nil to let the system
    /// pick the default handler (`terminalBundleID` empty, or the chosen app
    /// no longer installed).
    private func preferredTerminalURL() -> URL? {
        guard !terminalBundleID.isEmpty else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleID)
    }

    /// Open `file` (a directory, or a `.command` launcher) in the user's
    /// chosen terminal — or Apple Terminal when none is set / it's no longer
    /// installed. Explicitly choosing Terminal prevents a user's `.command`
    /// file association (for example, Script Editor) from intercepting the
    /// managed-session launcher. iTerm needs its application scripting API
    /// for `.command` launchers: asking a new iTerm instance to open the file
    /// creates a blank default window plus the command window, while asking
    /// the existing instance through NSWorkspace is accepted but ignored.
    /// `create window ... command` creates exactly one dedicated window. This
    /// is iTerm application automation, not Accessibility/UI scripting. Other
    /// terminals retain the NSWorkspace new-instance path.
    private func openWithTerminal(_ file: URL) {
        let isCommandLauncher = file.pathExtension == "command"
        let terminal = preferredTerminalURL()
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        if let app = terminal {
            let bundleID = Bundle(url: app)?.bundleIdentifier ?? app.lastPathComponent
            if isCommandLauncher && bundleID == "com.googlecode.iterm2" {
                openCommandInITerm(file, fallbackApp: app)
            } else {
                openWithWorkspace(file, app: app, mode: "new-application-instance")
            }
        } else {
            let accepted = NSWorkspace.shared.open(file)
            log("terminal open fallback file=\(boundedLogField(file.lastPathComponent)) accepted=\(accepted)")
        }
    }

    private func openWithWorkspace(_ file: URL, app: URL, mode: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        let bundleID = Bundle(url: app)?.bundleIdentifier ?? app.lastPathComponent
        log("terminal open requested file=\(boundedLogField(file.lastPathComponent)) terminal=\(boundedLogField(bundleID)) mode=\(mode)")
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config) { application, error in
            log("terminal open completed file=\(boundedLogField(file.lastPathComponent)) accepted=\(application != nil) pid=\(application?.processIdentifier.description ?? "-") error=\(boundedLogField(error?.localizedDescription))")
        }
    }

    private func openCommandInITerm(_ file: URL, fallbackApp: URL) {
        func shellQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        func appleScriptQuoted(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }

        let command = "exec \(shellQuoted(file.path))"
        let script = "tell application \"iTerm2\" to create window with default profile command \"\(appleScriptQuoted(command))\""
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] process in
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            log("terminal open completed file=\(boundedLogField(file.lastPathComponent)) accepted=\(process.terminationStatus == 0) mode=iterm-single-window status=\(process.terminationStatus) error=\(boundedLogField(detail))")
            if process.terminationStatus != 0 {
                DispatchQueue.main.async {
                    self?.openWithWorkspace(file, app: fallbackApp,
                                            mode: "new-application-fallback")
                }
            }
        }
        do {
            log("terminal open requested file=\(boundedLogField(file.lastPathComponent)) terminal=com.googlecode.iterm2 mode=iterm-single-window")
            try process.run()
        } catch {
            log("terminal open failed file=\(boundedLogField(file.lastPathComponent)) mode=iterm-single-window error=\(boundedLogField(error.localizedDescription))")
            openWithWorkspace(file, app: fallbackApp, mode: "new-application-fallback")
        }
    }

    /// Present the macOS app picker (an "Open With"-style chooser scoped to
    /// /Applications) so the user can select any terminal, then persist it.
    func chooseTerminalApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose Terminal App"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
        terminalBundleID = id
    }

    /// Opens a new terminal window at `path` in the user's chosen terminal.
    func openInTerminal(_ path: String) {
        openWithTerminal(URL(fileURLWithPath: path, isDirectory: true))
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// The provider command that resumes a session's conversation, or nil
    /// if its tool has no resume-by-id (Cursor/generic). Claude Code and Codex
    /// both resume by the session id we already store: `claude --resume <id>`
    /// / `codex resume <id>`. The id is single-quoted for the shell.
    func resumeCommand(for entry: SessionHistoryEntry) -> String? {
        let quotedID = "'" + entry.sessionID.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch entry.kind {
        case "claude": return "claude --resume \(quotedID)"
        case "codex":  return "codex resume \(quotedID)"
        default:       return nil
        }
    }

    /// Whether an unmanaged live row can be safely promoted right now. Resume
    /// restores a transcript, not an in-flight tool execution, so thinking,
    /// running, compacting, and error sessions are intentionally gated out.
    func canRelaunchAsManaged(_ session: SessionInfo) -> Bool {
        guard session.connected, !session.isManaged, !session.pendingReopen,
              session.kind == "claude" || session.kind == "codex",
              session.cwd != nil else { return false }
        return session.state == .idle || session.state == .waiting || session.state == .done
    }

    /// Explicitly promote a live Claude/Codex conversation to the managed
    /// tmux transport. The daemon gracefully stops the old process; its
    /// `session-ended` event is the handoff point that starts the resume.
    func relaunchAsManaged(_ session: SessionInfo) {
        let eligible = canRelaunchAsManaged(session)
        let alreadyPending = pendingManagedRelaunch.contains(session.id)
        log("managed relaunch click id=\(boundedLogField(session.id)) state=\(session.state.rawValue) connected=\(session.connected) managed=\(session.managed) pending=\(session.pendingReopen) kind=\(boundedLogField(session.kind)) cwd_present=\(session.cwd != nil) eligible=\(eligible) already_pending=\(alreadyPending)")
        guard eligible, !alreadyPending else {
            log("managed relaunch rejected-locally id=\(boundedLogField(session.id))")
            return
        }

        pendingManagedRelaunch.insert(session.id)
        log("managed relaunch requested id=\(boundedLogField(session.id)) slot=\(session.slot.map(String.init) ?? "-") state=\(session.state.rawValue) kind=\(boundedLogField(session.kind))")
        managedRelaunchStatus = ManagedRelaunchStatus(
            sessionID: session.id,
            sessionTitle: session.title,
            phase: .requesting,
            detail: "Waiting for FocalPoint to accept the handoff."
        )
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].pendingReopen = true
        }
        let client = self.client
        let targetID = session.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let response = client.request([
                "cmd": "relaunch-managed-session",
                "session": targetID,
            ], timeout: 2)
            guard response?["ok"] as? Bool == true else {
                let message = response?["error"] as? String
                    ?? "Could not reach the FocalPoint daemon."
                Task { @MainActor [weak self] in
                    self?.clearManagedRelaunch(targetID)
                    self?.setManagedRelaunchStatus(
                        id: targetID, phase: .rejected, detail: message
                    )
                    log("relaunchAsManaged: \(message)")
                }
                return
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.pendingManagedRelaunch.contains(targetID) else { return }
            self.clearManagedRelaunch(targetID)
            self.setManagedRelaunchStatus(
                id: targetID,
                phase: .timedOut,
                detail: "No managed replacement registered within 30 seconds."
            )
            log("relaunchAsManaged: timed out waiting for managed registration: \(targetID)")
        }
    }

    private func handleManagedRelaunchEvent(_ event: [String: Any]) {
        guard let id = event["session"] as? String,
              let status = event["status"] as? String else { return }
        log("managed relaunch event id=\(boundedLogField(id)) status=\(boundedLogField(status)) launch=\(boundedLogField(event["launch_id"])) tmux_server=\(boundedLogField(event["tmux_server"])) tmux_session=\(boundedLogField(event["tmux_session"])) error=\(boundedLogField(event["error"]))")
        switch status {
        case "quitting":
            setManagedRelaunchStatus(
                id: id, phase: .quitting,
                detail: "Gracefully stopping the current agent process."
            )
        case "launched":
            setManagedRelaunchStatus(
                id: id, phase: .launched,
                detail: "Waiting for the resumed agent to reconnect."
            )
            guard let launchID = event["launch_id"] as? String,
                  let tmuxServer = event["tmux_server"] as? String,
                  let tmuxSession = event["tmux_session"] as? String else {
                clearManagedRelaunch(id)
                setManagedRelaunchStatus(
                    id: id, phase: .failed,
                    detail: "The daemon returned an incomplete launch event."
                )
                return
            }
            if attachedManagedRelaunches.insert(launchID).inserted {
                openManagedTmuxSession(
                    tmuxSession, tmuxServer: tmuxServer, launchID: launchID
                )
            }
        case "complete":
            clearManagedRelaunch(id)
            setManagedRelaunchStatus(
                id: id, phase: .complete,
                detail: "The resumed agent registered successfully."
            )
        case "failed":
            clearManagedRelaunch(id)
            let message = event["error"] as? String ?? "The daemon could not complete the handoff."
            setManagedRelaunchStatus(id: id, phase: .failed, detail: message)
            log("managed relaunch failed: \(message)")
        default:
            break
        }
    }

    private func setManagedRelaunchStatus(
        id: String, phase: ManagedRelaunchPhase, detail: String
    ) {
        let existingTitle = managedRelaunchStatus?.sessionID == id
            ? managedRelaunchStatus?.sessionTitle : nil
        let title = existingTitle
            ?? sessions.first(where: { $0.id == id })?.title
            ?? "Session"
        managedRelaunchStatus = ManagedRelaunchStatus(
            sessionID: id,
            sessionTitle: title,
            phase: phase,
            detail: String(detail.prefix(240))
        )
    }

    func dismissManagedRelaunchStatus() {
        guard managedRelaunchStatus?.phase.isTerminal == true else { return }
        managedRelaunchStatus = nil
    }

    private func clearManagedRelaunch(_ id: String) {
        pendingManagedRelaunch.remove(id)
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].pendingReopen = false
        }
    }

    private func openManagedTmuxSession(
        _ tmuxSession: String, tmuxServer: String, launchID: String
    ) {
        let quotedSession = "'" + tmuxSession.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let quotedServer = "'" + tmuxServer.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/zsh -l
        TMUX_BIN=$(command -v tmux)
        if [ -z "$TMUX_BIN" ] && [ -x /opt/homebrew/bin/tmux ]; then TMUX_BIN=/opt/homebrew/bin/tmux; fi
        if [ -z "$TMUX_BIN" ] && [ -x /usr/local/bin/tmux ]; then TMUX_BIN=/usr/local/bin/tmux; fi
        if [ -z "$TMUX_BIN" ]; then print -u2 'tmux is not installed.'; exit 1; fi
        exec "$TMUX_BIN" -L \(quotedServer) attach-session -t \(quotedSession)
        """
        let launcher = FileManager.default.temporaryDirectory
            .appendingPathComponent("focalpoint-attach-\(launchID).command")
        do {
            try script.write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: launcher.path)
            log("managed relaunch attach requested launch=\(boundedLogField(launchID)) tmux_server=\(boundedLogField(tmuxServer)) tmux_session=\(boundedLogField(tmuxSession)) mode=new-window")
            openWithTerminal(launcher)
        } catch {
            log("openManagedTmuxSession: failed to write launcher: \(error)")
        }
    }

    /// Recover an ended session from History under the managed tmux launcher
    /// in a new terminal window at its working directory. Writes a temporary
    /// `.command` launcher and routes it through `openWithTerminal`; iTerm uses
    /// its one-window application command while other terminals use
    /// NSWorkspace. The resumed session re-registers with the daemon via its
    /// adapter hooks, so it reappears as a live session.
    func recoverSession(_ entry: SessionHistoryEntry) {
        launchManagedSession(entry)
    }

    private func launchManagedSession(_ entry: SessionHistoryEntry) {
        guard let cmd = resumeCommand(for: entry) else { return }
        let cwd = entry.cwd ?? NSHomeDirectory()
        let quotedCwd = "'" + cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let runner = NSHomeDirectory() + "/.config/focalpoint/focalpoint-run.sh"
        let quotedRunner = "'" + runner.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        #!/bin/zsh -l
        # FocalPoint managed session recovery — reopens \(entry.kind) session \(entry.sessionID).
        cd \(quotedCwd) 2>/dev/null || cd
        if [ ! -x \(quotedRunner) ]; then
          print -u2 'FocalPoint managed-session launcher is not installed.'
          exit 1
        fi
        exec \(quotedRunner) \(cmd)
        """
        let launcher = FileManager.default.temporaryDirectory
            .appendingPathComponent("focalpoint-resume-\(entry.sessionID).command")
        do {
            try script.write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: launcher.path)
        } catch {
            log("recoverSession: failed to write launcher: \(error)")
            return
        }
        openWithTerminal(launcher)
        optimisticallyReopen(entry)
    }

    /// Put the resumed session back in the list *immediately* (as
    /// "Reopening…") instead of waiting for its `SessionStart` hook to reach
    /// the daemon and come back as a `session` event — the resumed agent
    /// keeps the same id, so `upsertSession` merges into this row and clears
    /// `pendingReopen`. A timeout removes the placeholder if the real event
    /// never lands (resume was refused — e.g. a still-running bg agent — or
    /// the tool assigned a new id).
    private func optimisticallyReopen(_ entry: SessionHistoryEntry) {
        let operation: String
        if let idx = sessions.firstIndex(where: { $0.id == entry.sessionID }) {
            operation = "update"
            sessions[idx].pendingReopen = true
            sessions[idx].connected = true
        } else {
            operation = "insert"
            var s = SessionInfo(id: entry.sessionID, kind: entry.kind, label: entry.title,
                                name: nil, slot: nil, state: .idle, connected: true,
                                cwd: entry.cwd, firstSeen: Date(), lastChange: Date(), stats: [:])
            s.pendingReopen = true
            sessions.append(s)
        }
        log("optimistic reopen \(operation) id=\(boundedLogField(entry.sessionID)) kind=\(boundedLogField(entry.kind)) rows=\(sessions.count)")
        sortSessions()
        let targetID = entry.sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { [weak self] in
            guard let self else { return }
            // Only drop it if it's STILL just a placeholder — a real event
            // (same id) clears `pendingReopen`, in which case it's a genuine
            // live session now and must stay.
            if let idx = self.sessions.firstIndex(where: { $0.id == targetID }),
               self.sessions[idx].pendingReopen {
                self.sessions.remove(at: idx)
                log("optimistic reopen timeout-remove id=\(boundedLogField(targetID)) rows=\(self.sessions.count)")
            }
        }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A pane-local recovery command for a managed terminal whose normal
    /// provider hook was missed. The CLI independently verifies the private
    /// tmux server/pane before registering, so copying this string is safe;
    /// running it in an unrelated shell fails closed.
    func reRegisterCommand(for session: SessionInfo) -> String? {
        guard session.managed,
              ["claude", "codex", "cursor", "cursor-cli"].contains(session.kind)
        else { return nil }
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var fields = [
            "focalpoint", "re-register",
            "--session", quoted(session.id),
            "--kind", quoted(session.kind),
            "--title", quoted(session.title),
            "--state", "thinking",
        ]
        if let taskID = session.orchestratorTaskID {
            fields += ["--task-id", quoted(taskID)]
        }
        if let role = session.orchestrationRole {
            fields += ["--role", quoted(role)]
        }
        if let manager = session.managerTaskID {
            fields += ["--manager-task-id", quoted(manager)]
        }
        if let slot = session.slot {
            fields += ["--slot", String(slot)]
        }
        return fields.joined(separator: " ")
    }

    func copyReRegisterCommand(for session: SessionInfo) {
        guard let command = reRegisterCommand(for: session) else { return }
        copyToPasteboard(command)
        log("copied re-register command id=\(boundedLogField(session.id)) title=\(boundedLogField(session.title)) task_id=\(boundedLogField(session.orchestratorTaskID))")
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
