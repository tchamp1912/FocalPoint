// FocalPoint menu-bar app — shared translucent-material bridge, spacing scale,
// kind-icon mapping, and small view helpers reused by the dropdown, settings
// window, and desktop widget.
// MIT License.

import SwiftUI
import AppKit

// MARK: - NSVisualEffectView bridge (real macOS vibrancy, not a flat color)

/// Bridges NSVisualEffectView into SwiftUI. Use `.withinWindow` blending when
/// hosting inside a normal (opaque) titled NSWindow — it still renders a
/// correct frosted material even without real content behind the window.
/// Use `.behindWindow` only for windows we've explicitly made non-opaque /
/// borderless ourselves (see DesktopOverlayController), where it produces a
/// true see-through blur of whatever is behind the window.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var emphasized: Bool = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        v.isEmphasized = emphasized
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.isEmphasized = emphasized
    }
}

// MARK: - Spacing / radius scale (4pt rhythm)

enum Metrics {
    static let cardRadius: CGFloat = 14
    static let rowRadius: CGFloat = 8
    static let badgeRadius: CGFloat = 6
    static let hPad: CGFloat = 14
    static let vPad: CGFloat = 10
    /// Settings sidebar/detail backgrounds — kept high for legibility. The
    /// desktop widget has its own user-controlled translucency slider.
    static let settingsPaneOpacity: Double = 0.94
}

// MARK: - Budget alert color (client-only; not an AgentState)

/// Warning tint for a session that has crossed a user-configured token/cost
/// budget (Settings → Agent Integrations → Budget alerts). Deliberately not
/// tied to `AgentState`/the daemon's protocol — this is a client-side overlay
/// concept layered on top of live state (see `AppModel.isOverBudget`), passed
/// straight into `StateSwatch`'s free `color:` parameter like any other color.
let budgetWarningColor = Color(red: 1.0, green: 0.36, blue: 0.13)

// MARK: - State color swatch (used in dropdown, settings, and widget)

struct StateSwatch: View {
    let state: AgentState
    let color: Color
    var size: CGFloat = 10
    var body: some View {
        Image(systemName: state.symbolName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.5), radius: size * 0.3)
    }
}

// MARK: - Inline session rename

/// Hands the `NSWindow` hosting this SwiftUI view back to the caller once the
/// view is in a window. Needed because keyboard focus is a window/app-level
/// concept that SwiftUI's `@FocusState` alone can't reach: `@FocusState` only
/// decides *which view inside a key window* is first responder, and neither
/// of the windows this app puts text fields in is key by default.
private struct WindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    final class Probe: NSView {
        var onResolve: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onResolve?(window)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let v = Probe()
        v.onResolve = onResolve
        return v
    }

    func updateNSView(_ nsView: Probe, context: Context) {
        nsView.onResolve = onResolve
    }
}

/// A session's title, which turns into a text field while that session is the
/// one being renamed (PROTOCOL.md §3 `rename-session`).
///
/// The field edits the *override* rather than the visible title: it starts
/// empty for a session that has never been renamed, and uses the adapter's
/// own label as its placeholder. That makes the two outcomes obvious —
/// type a name to override the label, submit an empty field to drop back to
/// it — without needing a separate "reset" affordance.
///
/// `editingID` is owned by the enclosing list so only one row is ever in edit
/// mode, and so the row's own tap gesture (focus the session) can be
/// suppressed while typing.
struct SessionTitleField: View {
    let session: SessionInfo
    @ObservedObject var model: AppModel
    @Binding var editingID: String?
    var font: Font = .body

    @State private var draft = ""
    @FocusState private var focused: Bool

    private var isEditing: Bool { editingID == session.id }

    var body: some View {
        if isEditing {
            TextField(session.label ?? session.kind, text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .focused($focused)
                .lineLimit(1)
                .onSubmit(commit)
                .onExitCommand(perform: cancel)          // Esc cancels
                .onChange(of: focused) {
                    // Clicking away commits rather than silently discarding.
                    if !focused && isEditing { commit() }
                }
                .onAppear { draft = session.name ?? "" }
                // Claim keyboard focus at the app and window level before
                // asking SwiftUI for view-level focus — see takeKeyboardFocus.
                .background(WindowAccessor { window in
                    takeKeyboardFocus(in: window)
                })
        } else {
            Text(session.title)
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Make this text field actually typable.
    ///
    /// Three separate things have to be true, and none of them hold by
    /// default for the windows this app uses:
    ///
    /// 1. **The app must be active.** FocalPoint is an `LSUIElement` /
    ///    `.accessory` app, so it is never the active app just because you
    ///    clicked one of its panels — key events keep going to whatever you
    ///    were typing in before.
    /// 2. **The window must be key.** The desktop widget is a borderless
    ///    `.nonactivatingPanel`, and `NSWindow.canBecomeKey` is false for
    ///    borderless windows unless overridden (see `KeyablePanel` in
    ///    DesktopOverlay.swift).
    /// 3. **The field must be first responder** — that part is `@FocusState`.
    ///
    /// Ordering matters: activating and keying the window resets first
    /// responder, so view-level focus is requested afterwards, on the next
    /// runloop turn.
    private func takeKeyboardFocus(in window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { focused = true }
    }

    /// Hand the keyboard back to whatever the user was working in, so a
    /// rename doesn't leave an accessory app holding activation.
    private func releaseKeyboardFocus() {
        NSApp.deactivate()
    }

    private func commit() {
        model.renameSession(session, to: draft)
        editingID = nil
        releaseKeyboardFocus()
    }

    private func cancel() {
        editingID = nil
        releaseKeyboardFocus()
    }
}

// MARK: - Optional per-session stat badges (next to the elapsed timer)

/// Renders one compact badge per enabled stat the session actually has data
/// for. Nothing renders at all when a session has no reported stats yet —
/// this is deliberately silent rather than showing zeros/placeholders.
struct SessionStatsView: View {
    let stats: [SessionStat: Double]
    let visible: Set<SessionStat>
    var size: CGFloat = 9

    var body: some View {
        let ordered = SessionStat.allCases.filter { visible.contains($0) && stats[$0] != nil }
        if !ordered.isEmpty {
            HStack(spacing: 5) {
                ForEach(ordered) { stat in
                    HStack(spacing: 2) {
                        Image(systemName: stat.symbol).font(.system(size: size))
                        Text(stat.format(stats[stat]!))
                            .font(.system(size: size))
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                    .help(stat.label)
                }
            }
            // Badges must never absorb the row's space pressure: without
            // this, a long session name squeezes this column until each
            // number wraps onto several lines and the badges read as a
            // vertical stack. Fixed here rather than at each call site so
            // every surface that shows stats gets it.
            .fixedSize()
        }
    }
}

// MARK: - Context-window meter (thin bar under a session row)

// MARK: - Provider account usage meter

/// Shared quota bar for menu dropdown and desktop widget. The trailing
/// percent and reset-time columns are fixed-width so every row's gauge
/// starts and ends at the same x; the bar itself takes all remaining space.
struct UsageMeterBar: View {
    enum Style { case menu, widget }

    let label: String
    let labelWidth: CGFloat
    let percent: Double
    let reset: Date?
    var style: Style = .menu

    private var clamped: Double { min(max(percent, 0), 100) }

    var body: some View {
        HStack(spacing: style == .menu ? 7 : 5) {
            Text(label)
                .font(style == .menu ? .caption2 : .system(size: 9))
                .foregroundStyle(style == .menu ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            ProgressView(value: clamped, total: 100)
                .tint(clamped >= 90 ? .orange : .accentColor)
                .frame(maxWidth: .infinity)
                .layoutPriority(-1)
            Text("\(Int(clamped.rounded()))%")
                .font(style == .menu ? .caption2 : .system(size: 9))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 30, alignment: .trailing)
            if let reset {
                Text(resetLabel(reset))
                    .font(style == .menu ? .caption2 : .system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: style == .menu ? 56 : 48, alignment: .leading)
            }
        }
    }

    private func resetLabel(_ reset: Date) -> String {
        let time = reset.formatted(date: .omitted, time: .shortened)
        return style == .menu ? "→ \(time)" : time
    }
}

/// Color-grading thresholds for `ContextMeterView`, named so the cutoffs
/// read as intent rather than magic numbers: green below 60% full, amber
/// 60-85%, red above 85% (approaching a compaction/truncation risk).
private enum ContextMeterThresholds {
    static let amber = 0.6
    static let red = 0.85
}

/// A hairline full-width progress bar showing how full a session's context
/// window is (`SessionInfo.contextFraction`). Deliberately always shown when
/// data is available, with no user-facing hide toggle — unlike the optional
/// stat badges (`SessionStatsView`), this is a thin track+fill line, not
/// competing for the row's horizontal space, so there's nothing to declutter
/// by hiding it. Callers gate on `s.contextFraction != nil` at the call site;
/// this view itself just renders whatever fraction/window it's given.
struct ContextMeterView: View {
    let fraction: Double
    /// Current prompt occupancy in tokens — shown beside the window size so
    /// the bar isn't confused with the cumulative tokens-out badge.
    let occupancy: Double
    /// The absolute token window `fraction` is relative to — needed only for
    /// placing tick marks at fixed token intervals (see `ticks`), not for
    /// the fill itself.
    let window: Double
    var barHeight: CGFloat = 3

    private static func formatTokenCount(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", value / 1_000_000) }
        if value >= 1000 { return String(format: "%.0fk", (value / 1000).rounded()) }
        return String(Int(value))
    }

    private var fillColor: Color {
        if fraction >= ContextMeterThresholds.red { return .red }
        if fraction >= ContextMeterThresholds.amber { return .orange }
        return .green
    }

    /// Small tick every 100k tokens, a taller one every 250k — fixed
    /// absolute intervals rather than evenly-spaced fractions, so a tick
    /// always means "another 100k tokens" and the scale stays meaningful
    /// even as `window` itself gets corrected later (Settings → Agent
    /// Integrations): the bar's overall length changes, but what each tick
    /// means doesn't.
    ///
    /// The 100k and 250k marks are two independent grids, not one grid with
    /// some marks upgraded to "big" — 250k isn't a multiple of 100k, so a
    /// single `stride(by: 100_000)` can never land on it (250k, 750k, 1.25M,
    /// ... would all silently vanish; only 500k-multiples, where the two
    /// grids coincide, ever showed as "big"). Most visible on a short
    /// window: a Codex session's real 258,400-token window has a 250k mark
    /// well inside it, but the old single-stride version only ever produced
    /// 100k/200k and never got there.
    private var ticks: [(x: CGFloat, big: Bool)] {
        guard window > 0 else { return [] }
        var big: Set<Double> = []
        for t in stride(from: 250_000.0, to: window, by: 250_000.0) { big.insert(t) }
        var positions = Set(stride(from: 100_000.0, to: window, by: 100_000.0))
        positions.formUnion(big)
        return positions.sorted().map { t in (CGFloat(t / window), big.contains(t)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.secondary.opacity(0.15))
                        .frame(height: barHeight)
                    Capsule().fill(fillColor)
                        .frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)), height: barHeight)
                    ForEach(ticks, id: \.x) { tick in
                        Rectangle()
                            .fill(Color.primary.opacity(tick.big ? 0.4 : 0.2))
                            .frame(width: tick.big ? 1.5 : 1, height: tick.big ? barHeight + 4 : barHeight + 2)
                            .offset(x: geo.size.width * tick.x)
                    }
                }
            }
            .frame(height: barHeight + 4)
            Text("\(Self.formatTokenCount(occupancy)) / \(Self.formatTokenCount(window)) ctx")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .help("Current prompt size in the model's context window. The tokens-out badge is cumulative across the whole session, including compacted history.")
    }
}

// MARK: - Subtle row hover highlight (mouse-driven desktop UI)

private struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = Metrics.rowRadius
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.primary.opacity(hovering ? 0.07 : 0))
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = Metrics.rowRadius) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}
