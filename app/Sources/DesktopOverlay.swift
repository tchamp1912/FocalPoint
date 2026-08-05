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

    private var orientation: DesktopWidgetOrientation { model.desktopWidgetOrientation }
    /// Non-nil once the user has dragged the corner resize grip for this
    /// orientation: the root frame is pinned to it and overflowing session
    /// content scrolls. nil = content-fitted sizing (the original behavior).
    private var sizeOverride: CGSize? { model.widgetSize(for: orientation) }

    var body: some View {
        Group {
            switch orientation {
            case .vertical: verticalBody
            case .horizontal: horizontalBody
            }
        }
        // Translucency is applied only to the background layer (not the
        // window's alphaValue), so turning it up fades the panel toward raw
        // desktop without ever dimming the text/icons drawn on top of it.
        // See Glass.swift for what this renders as per OS version.
        .liquidGlass(.floatingPanel(opacity: model.interfaceTranslucency),
                     radius: Metrics.cardRadius)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .contextMenu { widgetContextMenu }
    }

    /// The little diagonal-lines affordance in the bottom-right corner. Live
    /// drags update the in-memory size (keeping the SwiftUI root frame in
    /// lockstep with the window so the clear background never gaps mid-drag);
    /// the size is persisted on mouse-up.
    private var resizeGrip: some View {
        ResizeGripView(
            orientation: orientation,
            onLiveResize: { model.previewWidgetSize($0, for: orientation) },
            onCommit: { model.setWidgetSize($0, for: orientation) }
        )
        .frame(width: 16, height: 16)
        .padding(2)
    }

    @ViewBuilder
    private var widgetContextMenu: some View {
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
        ForEach(DesktopWidgetOrientation.allCases) { option in
            Button {
                model.desktopWidgetOrientation = option
            } label: {
                if option == orientation {
                    Label(option.display, systemImage: "checkmark")
                } else {
                    Text(option.display)
                }
            }
        }
        if sizeOverride != nil {
            Divider()
            Button("Reset Widget Size") { model.resetWidgetSize(for: orientation) }
        }
        Divider()
        Button("Open Settings…") { onOpenSettings() }
        Button("Quit FocalPoint") { onQuit() }
    }

    // MARK: Vertical layout (the original tall card)

    private var verticalBody: some View {
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
            verticalSessionsArea
            verticalUsageSection
        }
        .padding(.vertical, 8)
        .frame(width: sizeOverride?.width ?? 260,
               height: sizeOverride?.height,
               alignment: .topLeading)
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

    /// Sessions are a plain stack while auto-sized (the fitting behavior the
    /// widget has always had) and swap to a ScrollView once the user pins a
    /// size, so overflow scrolls instead of silently clipping.
    @ViewBuilder
    private var verticalSessionsArea: some View {
        if model.sessions.isEmpty {
            // Spacers are zero-height in the auto-fitted window but center
            // the empty state inside a user-sized one.
            Spacer(minLength: 0)
            emptyState.frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        } else if sizeOverride != nil {
            ScrollView { sessionList }
        } else {
            sessionList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 3) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 15))
                .foregroundStyle(.tertiary)
            Text(model.connected ? "No active sessions" : "Daemon offline")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private var sessionList: some View {
        VStack(spacing: 1) {
            ForEach(model.elevatedSessions) { s in
                sessionRowButton(s)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func sessionRowButton(_ s: SessionInfo) -> some View {
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
        .contextMenu { sessionContextMenu(s) }
    }

    @ViewBuilder
    private func sessionContextMenu(_ s: SessionInfo) -> some View {
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

    @ViewBuilder
    private var verticalUsageSection: some View {
        if model.showUsage, !model.usage.isEmpty {
            Divider().padding(.horizontal, 10).padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) { usageRows }
                .padding(.horizontal, 11)
                .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var usageRows: some View {
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

    // MARK: Horizontal layout (wide strip, for top/bottom screen edges)

    private var horizontalBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let status = model.managedRelaunchStatus {
                ManagedRelaunchBanner(
                    status: status,
                    compact: true,
                    onDismiss: model.dismissManagedRelaunchStatus
                )
                .padding(.horizontal, 7)
                .padding(.top, 5)
            }
            HStack(alignment: .top, spacing: 0) {
                headerSegment
                Divider().padding(.vertical, 6)
                horizontalSessionsArea
                horizontalUsageSection
            }
        }
        .padding(.vertical, 6)
        .frame(width: sizeOverride?.width,
               height: sizeOverride?.height,
               alignment: .leading)
    }

    /// The strip's left segment doubles as the drag handle (same
    /// WindowDragHandle mechanism as the vertical header bar).
    private var headerSegment: some View {
        VStack(alignment: .leading, spacing: 1) {
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                FocalPointMark(color: model.aggregateStyle.color, assetName: "focalpoint-mark-widget")
                    .frame(width: 22, height: 14)
                Text("FocalPoint").font(.system(size: 11, weight: .semibold))
            }
            Text(model.connected ? model.aggregate.display : "Offline")
                .font(.system(size: 9))
                .foregroundStyle(model.connected ? .secondary : Color.red.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private var horizontalSessionsArea: some View {
        if model.sessions.isEmpty {
            Spacer(minLength: 0)
            emptyState
            Spacer(minLength: 0)
        } else if sizeOverride != nil {
            ScrollView(.horizontal) { cellRow }
        } else {
            // Auto-sized width grows with the session count; the settings
            // copy points at the grip as the way to cap it.
            cellRow
        }
    }

    private var cellRow: some View {
        HStack(alignment: .top, spacing: 2) {
            ForEach(model.elevatedSessions) { s in
                sessionCellButton(s)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    /// Fixed-width segment on the strip's right edge; scrolls vertically
    /// when a user-pinned height is too short for every meter.
    @ViewBuilder
    private var horizontalUsageSection: some View {
        if model.showUsage, !model.usage.isEmpty {
            Divider().padding(.vertical, 6)
            Group {
                if sizeOverride != nil {
                    ScrollView { VStack(alignment: .leading, spacing: 3) { usageRows } }
                } else {
                    VStack(alignment: .leading, spacing: 3) { usageRows }
                }
            }
            .frame(width: 165)
            .padding(.trailing, 4)
        }
    }

    @ViewBuilder
    private func sessionCellButton(_ s: SessionInfo) -> some View {
        // Same rename-outside-Button, attention, focus-outline, hover and
        // context-menu treatment as sessionRowButton above.
        Group {
            if renamingID == s.id {
                sessionCell(s)
            } else {
                Button { model.focusSession(s) } label: {
                    sessionCell(s)
                }
                .buttonStyle(.plain)
                .disabled(s.connected && s.slot == nil)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(attentionColor(for: s).opacity(
                    shouldHighlightAttention(s) ? 0.22 : 0
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .shadow(color: Color.accentColor.opacity(0.8), radius: 3)
                .opacity(s.id == model.focusedSessionID ? 1 : 0)
        )
        .hoverHighlight(cornerRadius: 6)
        .contextMenu { sessionContextMenu(s) }
    }

    /// Compact strip cell: slot + state + badges + elapsed on one line, the
    /// title below, and the context meter hairline when available. Stats
    /// badges and the model badge stay exclusive to the roomier vertical
    /// rows (they're all still in the dropdown).
    private func sessionCell(_ s: SessionInfo) -> some View {
        // Same stale/compacting/dimmed and budget-warning heuristics as
        // sessionRow — see that function and MenuContentView for the rationale.
        let overBudget = model.isOverBudget(s)
        let stale = model.isStale(s)
        let displayState: AgentState = stale ? .idle : s.state
        let dimmed = stale || s.state == .compacting || !s.connected || s.pendingReopen
        let swatchColor = overBudget ? budgetWarningColor : (model.styles[displayState] ?? defaultStyle(displayState)).color
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(s.slot.map(String.init) ?? "—")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if s.pendingReopen {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .help("Reopening — waiting for the resumed agent to reconnect")
                } else if !s.connected {
                    FocalPointMark(color: .secondary, assetName: "focalpoint-disconnected")
                        .frame(width: 11, height: 11)
                        .help("Disconnected — no update in a while. Click to try to reopen its terminal, or dismiss it.")
                } else {
                    StateSwatch(state: displayState, color: swatchColor, size: 8)
                        .help(stale ? "No update in a while — shown as idle since the agent may have died without a clean shutdown"
                              : s.state == .compacting ? "Compacting — momentarily between session identities, not agent activity"
                              : "")
                }
                Spacer(minLength: 2)
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
                if overBudget {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(budgetWarningColor)
                        .help("Over the configured token/cost budget")
                }
                Text(elapsedString(since: s.lastChange))
                    .font(.system(size: 9)).foregroundStyle(overBudget ? budgetWarningColor : .secondary)
                    .id(model.tick)
            }
            SessionTitleField(session: s, model: model,
                              editingID: $renamingID, font: .system(size: 11))
                .lineLimit(1)
            if let tokens = s.contextTokens {
                let kindOverride = model.contextWindowOverride(for: s.kind)
                if let fraction = s.contextFraction(kindOverride: kindOverride),
                   let window = s.effectiveContextWindow(kindOverride: kindOverride) {
                    ContextMeterView(fraction: fraction, occupancy: tokens, window: window)
                } else if let raw = s.contextTokensDisplay {
                    Text(raw).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(width: 150, alignment: .topLeading)
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.55 : 1)
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

// MARK: - Corner resize grip

/// Borderless panels get no resize chrome from AppKit (a `.borderless`
/// window has no frame view to hit-test), so the widget ships its own grip
/// in the bottom-right corner. Like WindowDragHandle, the work happens in a
/// plain NSView for the same reason SwiftUI gestures were abandoned for
/// window dragging (see the comment above): a direct mouseDragged → setFrame
/// loop is tracked entirely against screen coordinates, with no layout
/// feedback. Live deltas go to `onLiveResize` (in-memory, keeps the SwiftUI
/// root frame pinned to the dragged frame so the clear window background
/// never shows a gap); only `onCommit` (mouse-up) persists.
private struct ResizeGripView: NSViewRepresentable {
    let orientation: DesktopWidgetOrientation
    let onLiveResize: (CGSize) -> Void
    let onCommit: (CGSize) -> Void

    final class GripView: NSView {
        var orientation: DesktopWidgetOrientation = .vertical
        var onLiveResize: ((CGSize) -> Void)?
        var onCommit: ((CGSize) -> Void)?
        private var dragStartMouse: NSPoint?
        private var dragStartFrame: NSRect = .zero

        // y-down drawing (bottom-right corner = maxX/maxY). This view
        // handles its own mouse events and must stay out of
        // isMovableByWindowBackground's way.
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            // No public diagonal-resize cursor; crosshair is the closest
            // "this adjusts something" signal.
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath()
            path.lineWidth = 1.2
            path.lineCapStyle = .round
            for i in 0..<3 {
                let inset = CGFloat(i) * 3.5 + 3.5
                path.move(to: NSPoint(x: bounds.maxX - inset, y: bounds.maxY - 1.5))
                path.line(to: NSPoint(x: bounds.maxX - 1.5, y: bounds.maxY - inset))
            }
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragStartMouse = NSEvent.mouseLocation
            dragStartFrame = window.frame
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let start = dragStartMouse else { return }
            let current = NSEvent.mouseLocation
            let minSize = orientation.minWidgetSize
            let maxSize = orientation.maxWidgetSize
            let width = min(max(dragStartFrame.width + current.x - start.x, minSize.width), maxSize.width)
            let height = min(max(dragStartFrame.height - (current.y - start.y), minSize.height), maxSize.height)
            // Bottom-right grip: the top edge and left edge stay pinned, so
            // the origin moves down as the window grows taller.
            let origin = NSPoint(x: dragStartFrame.origin.x, y: dragStartFrame.maxY - height)
            window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
            onLiveResize?(CGSize(width: width, height: height))
        }

        override func mouseUp(with event: NSEvent) {
            if let size = window?.frame.size { onCommit?(size) }
            dragStartMouse = nil
        }
    }

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.orientation = orientation
        view.onLiveResize = onLiveResize
        view.onCommit = onCommit
        return view
    }

    func updateNSView(_ nsView: GripView, context: Context) {
        nsView.orientation = orientation
        nsView.onLiveResize = onLiveResize
        nsView.onCommit = onCommit
        nsView.needsDisplay = true
    }
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
    private var cancellables: Set<AnyCancellable> = []

    /// Set by the app delegate so the widget's context menu can open Settings.
    var onOpenSettings: (() -> Void)?

    private static let originXKey = "desktopWidgetOriginX"
    private static let originYKey = "desktopWidgetOriginY"

    /// Pending top-edge re-anchor; see requestTopAnchor().
    private var topAnchorRequest: (top: CGFloat, at: CFAbsoluteTime)?

    init(model: AppModel) {
        self.model = model
        super.init()
        // @Published emits its current value immediately to new subscribers,
        // so this also sets correct initial visibility at launch.
        let visibilityInputs = Publishers.CombineLatest4(
            model.$desktopWidgetMode, model.$aggregate,
            model.$sessions, model.$desktopWidgetHotkeyHidden
        )
        Publishers.CombineLatest(visibilityInputs, model.$managedRelaunchStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] inputs, relaunchStatus in
                let (mode, aggregate, sessions, hotkeyHidden) = inputs
                self?.updateVisibility(mode: mode, aggregate: aggregate, sessions: sessions,
                                        hotkeyHidden: hotkeyHidden,
                                        hasRelaunchStatus: relaunchStatus != nil)
            }
            .store(in: &cancellables)

        // Orientation flips and size-override changes (including Reset and
        // live grip updates) re-fit the window around a different content
        // size; keep the top edge stationary across that refit.
        model.$desktopWidgetOrientation.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestTopAnchor() }
            .store(in: &cancellables)
        model.$widgetSizeVertical.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestTopAnchor() }
            .store(in: &cancellables)
        model.$widgetSizeHorizontal.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestTopAnchor() }
            .store(in: &cancellables)
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

    /// AppKit re-fits a contentViewController-driven window from its origin
    /// (bottom-left), so when the layout changes shape — orientation flip,
    /// size override change/reset — the bottom edge stays put and the widget
    /// appears to jump relative to the top screen edge it's usually parked
    /// against. Recording the top edge here and re-applying it in
    /// windowDidResize keeps the widget visually stationary across the
    /// refit. The timestamp guard stops a request that never produced a
    /// resize from hijacking an unrelated later one; grip drags self-anchor
    /// (top stays pinned by construction), so consuming them here is a
    /// dy ≈ 0 no-op.
    private func requestTopAnchor() {
        guard let p = panel, p.isVisible else { return }
        topAnchorRequest = (top: p.frame.maxY, at: CFAbsoluteTimeGetCurrent())
    }

    func windowDidResize(_ notification: Notification) {
        guard let request = topAnchorRequest, let p = panel else { return }
        topAnchorRequest = nil
        guard CFAbsoluteTimeGetCurrent() - request.at < 0.5 else { return }
        let dy = request.top - p.frame.maxY
        guard abs(dy) > 0.5 else { return }
        var frame = p.frame
        frame.origin.y += dy
        p.setFrame(frame, display: true)
        persistPosition()
    }
}
