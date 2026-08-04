// FocalPoint menu-bar app — desktop widget.
//
// Architecture decision (Task 3): this is a borderless, non-activating
// floating NSPanel (styleMask [.borderless, .nonactivatingPanel], level
// .floating, collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary]) —
// NOT a true desktop-level window (CGWindowLevelForKey(.desktopIconWindow)).
// A real desktop-level window sits BEHIND all normal app windows, which is
// right for a passive click-through HUD but wrong once the widget needs to
// be clickable: while you're working in another app, a desktop-level window
// would be permanently covered and unreachable. Floating + non-activating
// keeps it glanceable and clickable above normal windows, across every
// Space and over full-screen apps, while `.nonactivatingPanel` +
// `becomesKeyOnlyIfNeeded` means clicking it never steals focus/keyboard
// input from whatever app you were just typing into — the same trick HUD-
// style utility panels (screenshot toolbar, Spotlight-adjacent panels) use.
//
// Trade-off vs. pure click-through: this widget is no longer click-through
// everywhere. Only the drag handle bar is a "background chrome" region (drag
// to reposition, right-click for the mode/settings/quit menu); the session
// rows below it are real Buttons that focus/bounce the session, matching
// dropdown row behavior. There is no way to have both "sits behind and
// ignores clicks" and "rows are clickable" at once, so click-through was
// dropped in favor of interactivity, per the task's instruction to pick one.
// MIT License.

import SwiftUI
import AppKit
import Combine

// MARK: - The widget's SwiftUI content

struct DesktopWidgetView: View {
    @ObservedObject var model: AppModel
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    /// Session currently being renamed inline, if any.
    @State private var renamingID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dragHandle
            Divider().padding(.horizontal, 10)
            if let status = model.managedRelaunchStatus {
                ManagedRelaunchBanner(
                    status: status,
                    compact: true,
                    onDismiss: model.dismissManagedRelaunchStatus
                )
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                Divider().padding(.horizontal, 10)
            }
            content
        }
        .padding(.vertical, 8)
        .frame(width: 260, alignment: .leading)
        // Translucency is applied only to the background layer (not the
        // window's alphaValue), so turning it up fades the panel toward raw
        // desktop without ever dimming the text/icons drawn on top of it.
        // See Glass.swift for what this renders as per OS version.
        .liquidGlass(.floatingPanel(opacity: model.interfaceTranslucency),
                     radius: Metrics.cardRadius)
        .contextMenu {
            ForEach(DesktopWidgetMode.allCases) { mode in
                Button {
                    model.desktopWidgetMode = mode
                } label: {
                    if model.desktopWidgetMode == mode {
                        Label(mode.display, systemImage: "checkmark")
                    } else {
                        Text(mode.display)
                    }
                }
            }
            Divider()
            Button("Open Settings…") { onOpenSettings() }
            Button("Quit FocalPoint") { onQuit() }
        }
    }

    /// Drag handle bar: the one "background chrome" region — drag to move
    /// the widget, right-click anywhere in the widget for the mode menu.
    private var dragHandle: some View {
        HStack(spacing: 7) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            FocalPointMark(color: model.aggregateStyle.color, assetName: "focalpoint-mark-widget")
                .frame(width: 28, height: 18)
            Text("FocalPoint").font(.system(size: 12, weight: .semibold))
            Spacer()
            Text(model.connected ? model.aggregate.display : "Offline")
                .font(.system(size: 10))
                .foregroundStyle(model.connected ? .secondary : Color.red.opacity(0.85))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if model.sessions.isEmpty {
            VStack(spacing: 3) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 15))
                    .foregroundStyle(.tertiary)
                Text(model.connected ? "No active sessions" : "Daemon offline")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            } else {
            VStack(spacing: 1) {
                ForEach(model.elevatedSessions) { s in
                    // See MenuContentView: the row being renamed must stay
                    // outside the Button, because `.disabled()` would
                    // propagate into the text field and make it unusable.
                    Group {
                        if renamingID == s.id {
                            sessionRow(s)
                        } else {
                            Button { model.focusSession(s) } label: {
                                sessionRow(s)
                            }
                            .buttonStyle(.plain)
                            // See MenuContentView: a disconnected session is
                            // still focusable by id; only a connected slotless
                            // row is truly un-focusable.
                            .disabled(s.connected && s.slot == nil)
                        }
                    }
                    // The daemon owns attention priority. Highlight only the
                    // next row it selected instead of independently inferring
                    // priority from state in the app.
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(attentionColor(for: s).opacity(
                                shouldHighlightAttention(s) ? 0.22 : 0
                            ))
                    )
                    // Persistent outline for the last session FocalPoint itself
                    // focused. A stroked edge, not a fill: on the liquid-glass
                    // background a translucent fill washes out and barely
                    // reads, but a solid-color border stays crisp regardless
                    // of what's behind it. Full opacity + a matching glow
                    // (same trick StateSwatch uses) so the edge lifts off the
                    // glass instead of blending into it. Layered under the
                    // transient hover tint so both can show at once.
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 1.5)
                            .shadow(color: Color.accentColor.opacity(0.8), radius: 3)
                            .opacity(s.id == model.focusedSessionID ? 1 : 0)
                    )
                    .hoverHighlight(cornerRadius: 6)
                    // Row-scoped, so it shadows the widget's own mode menu
                    // here; the drag handle remains the place to right-click
                    // for widget options.
                    .contextMenu {
                        Button("Rename\u{2026}") { renamingID = s.id }
                        Divider()
                        Button("Relaunch as Managed Session") {
                            model.relaunchAsManaged(s)
                        }
                        .disabled(!model.canRelaunchAsManaged(s))
                        Divider()
                        // See MenuContentView: End Session quits the agent
                        // process; Remove Session just drops the row.
                        Button("End Session", role: .destructive) { model.quitSession(s) }
                        Button("Remove Session") { model.removeSession(s) }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            }
            if model.showUsage, !model.usage.isEmpty {
                Divider().padding(.horizontal, 10).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.usage) { usage in
                        if let percent = usage.fiveHourUsed {
                            usageRow(usage.provider, label: "5h", percent: percent, reset: usage.fiveHourResetsAt)
                        }
                        if let percent = usage.sevenDayUsed {
                            usageRow(usage.provider, label: "Wk", percent: percent, reset: usage.sevenDayResetsAt)
                        }
                        if let percent = usage.primaryUsed {
                            usageRow(usage.provider, label: usage.primaryMeterLabel, percent: percent, reset: usage.primaryResetsAt)
                        }
                        if let percent = usage.secondaryUsed {
                            usageRow(usage.provider, label: usage.secondaryMeterLabel, percent: percent, reset: usage.secondaryResetsAt)
                        }
                        if let spend = model.trackedAPISpend(for: usage) {
                            apiSpendRow(usage, spend: spend)
                        }
                        if let input = model.trackedAPIInputTokens(for: usage),
                           let output = model.trackedAPIOutputTokens(for: usage) {
                            Text("\(usage.displayName) \(Int(input)) in / \(Int(output)) out \(model.apiUsageTrackingLabel)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 11)
                .padding(.top, 6)
            }
        }
    }

    private func usageRow(_ provider: String, label: String, percent: Double, reset: Date?) -> some View {
        UsageMeterBar(label: "\(provider.capitalized) \(label)",
                      labelWidth: 54, percent: percent, reset: reset, style: .widget)
    }

    private func apiSpendRow(_ usage: ProviderUsage, spend: Double) -> some View {
        Text("\(usage.displayName) $\(spend.formatted(.number.precision(.fractionLength(2)))) \(model.apiUsageTrackingEnabled ? "since reset" : usage.apiSpendPeriodLabel)")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func shouldHighlightAttention(_ session: SessionInfo) -> Bool {
        session.connected && !session.pendingReopen && !model.isStale(session)
            && model.isNextAttentionSession(session)
    }

    private func attentionColor(for session: SessionInfo) -> Color {
        (model.styles[session.state] ?? defaultStyle(session.state)).color
    }

    private func sessionRow(_ s: SessionInfo) -> some View {
        let hasStats = SessionStat.allCases.contains { model.visibleStats.contains($0) && s.stats[$0] != nil }
        let overBudget = model.isOverBudget(s)
        // Same stale heuristic (including approval prompts) as MenuContentView's sessionRow — see that
        // file (and AppModel.isStale) for the rationale.
        let stale = model.isStale(s)
        let displayState: AgentState = stale ? .idle : s.state
        // Same compacting-dim rationale as MenuContentView's sessionRow —
        // see that file (and AppModel.isStale) for the rationale. A
        // disconnected (sweep-reaped) session is dimmed too.
        let dimmed = stale || s.state == .compacting || !s.connected || s.pendingReopen
        // Same warning-color swap + elapsed-time tint as MenuContentView's
        // sessionRow — see that file for the rationale.
        let swatchColor = overBudget ? budgetWarningColor : (model.styles[displayState] ?? defaultStyle(displayState)).color
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(s.slot.map(String.init) ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .frame(width: 15, alignment: .center)
                    .foregroundStyle(.secondary)
                if s.pendingReopen {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("Reopening — waiting for the resumed agent to reconnect")
                } else if !s.connected {
                    FocalPointMark(color: .secondary, assetName: "focalpoint-disconnected")
                        .frame(width: 12, height: 12)
                        .help("Disconnected — no update in a while. Click to try to reopen its terminal, or dismiss it.")
                } else {
                    StateSwatch(state: displayState, color: swatchColor, size: 8)
                        .help(stale ? "No update in a while — shown as idle since the agent may have died without a clean shutdown"
                              : s.state == .compacting ? "Compacting — momentarily between session identities, not agent activity"
                              : "")
                }
                SessionTitleField(session: s, model: model,
                                  editingID: $renamingID, font: .system(size: 11))
                if overBudget {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(budgetWarningColor)
                        .help("Over the configured token/cost budget")
                }
                Spacer(minLength: 4)
                orchestrationBadge(s)
                if s.isManaged {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        .fixedSize()
                        .help("Managed session — FocalPoint can route attention and input to it precisely in the background")
                }
                if model.showModelBadge, let badge = s.modelBadge {
                    Text(badge).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(elapsedString(since: s.lastChange))
                    .font(.system(size: 10)).foregroundStyle(overBudget ? budgetWarningColor : .secondary)
                    .id(model.tick)
            }
            if hasStats {
                HStack {
                    Spacer()
                    SessionStatsView(stats: s.stats, visible: model.visibleStats)
                }
                .padding(.trailing, 1)
            }
            // Always shown when data is available — no settings gate, unlike
            // the optional stat badges above. It's a hairline bar, not a
            // badge, so it doesn't compete for the row's horizontal space.
            // Leading inset matches where the stat badge icons actually
            // start (the slot number above is a plain centered Text, not a
            // filled circle, so it has a few points of built-in inset the
            // meter otherwise lacks) — without it the meter reads as
            // starting a touch too far left of everything above it.
            if let tokens = s.contextTokens {
                let kindOverride = model.contextWindowOverride(for: s.kind)
                if let fraction = s.contextFraction(kindOverride: kindOverride),
                   let window = s.effectiveContextWindow(kindOverride: kindOverride) {
                    ContextMeterView(fraction: fraction, occupancy: tokens, window: window)
                        .padding(.leading, 8)
                        .padding(.top, 3)
                } else if let raw = s.contextTokensDisplay {
                    // Window unknown/exceeded — an honest count beats a
                    // percentage against a guess we no longer trust.
                    Text(raw).font(.system(size: 9)).foregroundStyle(.tertiary)
                        .padding(.leading, 8)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.55 : 1)
    }

    @ViewBuilder
    private func orchestrationBadge(_ session: SessionInfo) -> some View {
        if let number = model.orchestratorNumber(for: session) {
            let count = model.managedSessionCount(for: session)
            Text("O\(number)·\(count)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.purple)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(Capsule().fill(Color.purple.opacity(0.14)))
                .fixedSize()
                .help("Orchestrator O\(number) — manages \(count) session\(count == 1 ? "" : "s")")
        } else if let number = model.managingOrchestratorNumber(for: session),
                  let manager = model.managingOrchestrator(for: session) {
            Text("O\(number)")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.purple)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .overlay(Capsule().stroke(Color.purple.opacity(0.45), lineWidth: 1))
                .fixedSize()
                .help("Managed by O\(number): \(manager.title)")
        }
    }
}

// MARK: - Native window dragging

/// Marks this region as window-drag background: combined with
/// `panel.isMovableByWindowBackground = true` (set in `build()` below),
/// AppKit moves the window itself when the user mouse-downs-and-drags here
/// — no event handling on our end at all, so it's tracked entirely by the
/// window server, independent of SwiftUI's view tree.
///
/// The previous implementation used a SwiftUI `DragGesture(coordinateSpace:
/// .global)` and repositioned the panel by hand in `onChanged`. `.global` is
/// relative to this same window, so moving the window mid-gesture fed back
/// into the gesture's own coordinate space every frame — SwiftUI had to
/// re-layout against a target that had just moved out from under it,
/// producing the "stutters like crazy" jitter. A stopgap replacement using
/// `NSWindow.performDrag(with:)` turned out to be the wrong API too — that
/// one starts a drag-*and-drop* session (for dragging pasteboard content out
/// of a view), not a window-move session, so it silently did nothing.
/// `isMovableByWindowBackground` is the actual mechanism AppKit provides for
/// "let the user reposition a borderless window by dragging a chrome
/// region" — session row Buttons opt out of it automatically (NSControl
/// defaults `mouseDownCanMoveWindow` to false), so they stay clickable.
private struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

// MARK: - Panel

/// `NSWindow.canBecomeKey` is hardcoded to false for borderless windows, and
/// this widget is `[.borderless, .nonactivatingPanel]` — so without this
/// override a text field inside it can never become first responder and
/// silently swallows every keystroke (the inline session rename).
///
/// Overriding it does *not* make the panel grabby: `becomesKeyOnlyIfNeeded`
/// (set in `build()`) still means AppKit only hands it key status when the
/// user clicks a view that actually wants text input, so clicking a session
/// row to focus an agent continues to leave your current app's keyboard
/// focus alone.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Window controller

/// Owns the NSPanel, reacts to model changes (mode/aggregate/sessions) to
/// decide visibility, and handles drag-to-reposition + position persistence.
@MainActor
final class DesktopOverlayController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let model: AppModel
    private var cancellable: AnyCancellable?

    /// Set by the app delegate so the widget's context menu can open Settings.
    var onOpenSettings: (() -> Void)?

    private static let originXKey = "desktopWidgetOriginX"
    private static let originYKey = "desktopWidgetOriginY"

    init(model: AppModel) {
        self.model = model
        super.init()
        // @Published emits its current value immediately to new subscribers,
        // so this also sets correct initial visibility at launch.
        let visibilityInputs = Publishers.CombineLatest4(
            model.$desktopWidgetMode, model.$aggregate,
            model.$sessions, model.$desktopWidgetHotkeyHidden
        )
        cancellable = Publishers.CombineLatest(visibilityInputs, model.$managedRelaunchStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inputs, relaunchStatus in
                let (mode, aggregate, sessions, hotkeyHidden) = inputs
                self?.updateVisibility(mode: mode, aggregate: aggregate, sessions: sessions,
                                        hotkeyHidden: hotkeyHidden,
                                        hasRelaunchStatus: relaunchStatus != nil)
            }
    }

    private func updateVisibility(mode: DesktopWidgetMode, aggregate: AgentState,
                                   sessions: [SessionInfo], hotkeyHidden: Bool,
                                   hasRelaunchStatus: Bool) {
        guard !hotkeyHidden else { setVisible(false); return }
        switch mode {
        case .hidden:
            setVisible(false)
        case .always:
            setVisible(true)
        case .autoHideIdle:
            setVisible(aggregate != .idle || !sessions.isEmpty || hasRelaunchStatus)
        }
    }

    private func setVisible(_ visible: Bool) {
        if visible {
            if panel == nil { build() }
            panel?.orderFront(nil)
        } else {
            panel?.orderOut(nil)
        }
    }

    private func build() {
        let p = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 140),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.isMovableByWindowBackground = true
        p.hasShadow = true
        p.isFloatingPanel = true
        p.level = .floating
        // Never steals key focus just by being clicked; buttons still work.
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.delegate = self

        let view = DesktopWidgetView(
            model: model,
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onQuit: { NSApp.terminate(nil) }
        )
        p.contentViewController = NSHostingController(rootView: view)
        panel = p
        positionInitially()
    }

    // MARK: Position persistence (UserDefaults, not hardcoded top-right)

    private func positionInitially() {
        guard let p = panel else { return }
        let d = UserDefaults.standard
        if d.object(forKey: Self.originXKey) != nil, d.object(forKey: Self.originYKey) != nil {
            let x = d.double(forKey: Self.originXKey)
            let y = d.double(forKey: Self.originYKey)
            p.setFrameOrigin(CGPoint(x: x, y: y))
            if !isOnAnyScreen(p.frame) { defaultPosition() }
        } else {
            defaultPosition()
        }
    }

    private func defaultPosition() {
        guard let p = panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = p.frame.size
        let margin: CGFloat = 20
        p.setFrameOrigin(NSPoint(x: vf.maxX - size.width - margin, y: vf.maxY - size.height - margin))
    }

    private func isOnAnyScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { $0.frame.intersects(frame) }
    }

    private func persistPosition() {
        guard let p = panel else { return }
        let d = UserDefaults.standard
        d.set(Double(p.frame.origin.x), forKey: Self.originXKey)
        d.set(Double(p.frame.origin.y), forKey: Self.originYKey)
    }

    func windowDidMove(_ notification: Notification) {
        persistPosition()
    }
}
