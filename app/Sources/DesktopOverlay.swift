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
    /// Reports grip drag start/end so the window controller can keep
    /// mid-drag content refits pinned to the same corner as the grip.
    var onGripDragChanged: (Bool) -> Void

    /// Session currently being renamed inline, if any.
    @State private var renamingID: String?

    private var orientation: DesktopWidgetOrientation { model.desktopWidgetOrientation }
    /// Non-nil once the user has dragged the corner resize grip for this
    /// orientation: the widget's width is pinned to it. Height is always
    /// content-fitted — only the horizontal strip scrolls (its cells) when
    /// they overflow a pinned width.
    private var widthOverride: CGFloat? { model.widgetWidth(for: orientation) }

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

    /// The little vertical-ticks affordance in the bottom-right corner.
    /// Width-only by design (height fits the content); live drags update the
    /// in-memory width so the SwiftUI root frame stays in lockstep with the
    /// window, and the width is persisted on mouse-up.
    private var resizeGrip: some View {
        ResizeGripView(
            orientation: orientation,
            onLiveResize: { model.previewWidgetWidth($0, for: orientation) },
            onCommit: { model.setWidgetWidth($0, for: orientation) },
            onDragChanged: onGripDragChanged
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
        Button {
            model.compactWidgetRows.toggle()
        } label: {
            if model.compactWidgetRows {
                Label("Compact Rows", systemImage: "checkmark")
            } else {
                Text("Compact Rows")
            }
        }
        if widthOverride != nil {
            Divider()
            Button("Reset Widget Width") { model.resetWidgetWidth(for: orientation) }
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
        .frame(width: widthOverride ?? 260, alignment: .leading)
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

    /// Height always fits the content (only the width is user-pinnable), so
    /// there is nothing to scroll here — the stack grows downward from the
    /// controller-anchored top edge as sessions arrive.
    @ViewBuilder
    private var verticalSessionsArea: some View {
        if model.sessions.isEmpty {
            emptyState.frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 0) {
                if !model.activeSessions.isEmpty { sessionList }
                if !model.backlogSessions.isEmpty { backlogSection }
            }
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
            ForEach(model.activeSessions) { s in
                sessionRowButton(s)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    /// Parked-but-still-live sessions (PROTOCOL.md §3 backlog), kept in
    /// their own section below the active list: they keep reporting and
    /// stay clickable, but they've left the aggregate/attention routing
    /// and released their numbered keys.
    private var backlogSection: some View {
        VStack(spacing: 0) {
            Divider().padding(.horizontal, 10)
            HStack(spacing: 5) {
                Image(systemName: "tray")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("Backlog · \(model.backlogSessions.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            VStack(spacing: 1) {
                ForEach(model.backlogSessions) { s in
                    sessionRowButton(s)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
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
                // row is truly un-focusable — unless it's backlogged,
                // which the daemon keeps focusable by id (§3).
                .disabled(s.connected && s.slot == nil && !s.backlogged)
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
        slotDestinationMenu(s)
        Divider()
        Button("Relaunch as Managed Session") {
            model.relaunchAsManaged(s)
        }
        .disabled(!model.canRelaunchAsManaged(s))
        // Same parking action as the dropdown (PROTOCOL.md §3
        // set-session-backlogged); live sessions only.
        if s.backlogged {
            Button("Move to Active") { model.setSessionBacklogged(s, false) }
                .disabled(!s.connected)
        } else {
            Button("Move to Backlog") { model.setSessionBacklogged(s, true) }
                .disabled(!s.connected)
        }
        Divider()
        // See MenuContentView: End Session quits the agent
        // process; Remove Session just drops the row.
        Button("End Session", role: .destructive) { model.quitSession(s) }
        Button("Remove Session") { model.removeSession(s) }
    }

    /// The same Move to Slot menu the dropdown offers (PROTOCOL.md §3/§4
    /// move-slot + swap-slots): free slots move (sparse placement), occupied
    /// slots swap. Live, active rows only — a backlogged session holds no
    /// slot until it's moved back to active.
    @ViewBuilder
    private func slotDestinationMenu(_ s: SessionInfo) -> some View {
        if s.connected, !s.backlogged {
            let openSlots = model.freeSlots.filter { $0 != s.slot }
            let otherSlotted = model.activeSessions.filter { $0.id != s.id && $0.connected && $0.slot != nil }
            if !openSlots.isEmpty || (s.slot != nil && !otherSlotted.isEmpty) {
                Menu("Move to Slot") {
                    ForEach(openSlots, id: \.self) { n in
                        Button("#\(n) \u{00B7} Empty") { model.moveSessionToSlot(s, slot: n) }
                    }
                    if s.slot != nil, !openSlots.isEmpty, !otherSlotted.isEmpty {
                        Divider()
                    }
                    if s.slot != nil {
                        ForEach(otherSlotted) { other in
                            Button("Swap with #\(other.slot!) \u{00B7} \(other.title)") {
                                model.swapSlots(s, other)
                            }
                        }
                    }
                }
            }
        }
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

    // MARK: Horizontal layout (one-line ticker strip, for top/bottom screen edges)
    //
    // The strip is NOT the vertical card turned sideways: it's a single-row
    // ticker. One-line session chips (slot · state · name · elapsed), the
    // aggregate as a compact status segment on the left (doubling as the
    // drag handle), parked sessions dimmed behind a tray glyph, and account
    // usage compressed to a trailing summary line. Stats badges and the
    // model badge stay exclusive to the roomier vertical rows (and the
    // dropdown).

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
            HStack(spacing: 0) {
                statusSegment
                Divider().padding(.vertical, 5)
                horizontalSessionsArea
                usageTail
            }
        }
        .padding(.vertical, 5)
        .frame(width: widthOverride, alignment: .leading)
    }

    /// Compact left segment — brand mark + aggregate state, no title text
    /// (the mark is the identity; strip width is for sessions). Doubles as
    /// the drag handle, same WindowDragHandle mechanism as the vertical
    /// header bar.
    private var statusSegment: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            FocalPointMark(color: model.aggregateStyle.color, assetName: "focalpoint-mark-widget")
                .frame(width: 20, height: 13)
            Text(model.connected ? model.aggregate.display : "Offline")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(model.connected ? (model.aggregate == .idle ? Color.secondary : Color.primary) : Color.red.opacity(0.85))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private var horizontalSessionsArea: some View {
        if model.sessions.isEmpty {
            // Spacers are zero-width while auto-sized but center the empty
            // state across a user-pinned width.
            Spacer(minLength: 8)
            emptyState
            Spacer(minLength: 8)
        } else if widthOverride != nil {
            ScrollView(.horizontal) { chipStrip }
        } else {
            // Auto-sized width grows with the session count; the settings
            // copy points at the grip as the way to cap it.
            chipStrip
        }
    }

    private var chipStrip: some View {
        HStack(spacing: 3) {
            ForEach(model.activeSessions) { s in
                sessionChipButton(s)
            }
            // Parked sessions trail the active chips, dimmed, behind a tray
            // glyph — same backlog semantics as the vertical section.
            if !model.backlogSessions.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "tray")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Text("\(model.backlogSessions.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 4)
                ForEach(model.backlogSessions) { s in
                    sessionChipButton(s)
                }
                .opacity(0.65)
            }
        }
        .padding(.horizontal, 4)
    }

    /// Trailing one-line account-usage summary: only the numbers survive
    /// here ("Claude 5h 42% · Wk 18%"); the full meter bars and reset
    /// times stay in the vertical layout and the dropdown.
    @ViewBuilder
    private var usageTail: some View {
        if model.showUsage, !model.usage.isEmpty {
            Divider().padding(.vertical, 5)
            HStack(spacing: 10) {
                ForEach(model.usage) { u in
                    Text(usageTailText(u))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .help("Account usage — percentage of each window used. Meter bars and reset times are in the dropdown and the vertical widget.")
        }
    }

    private func usageTailText(_ u: ProviderUsage) -> String {
        var parts: [String] = []
        if let p = u.fiveHourUsed { parts.append("5h \(Int(p.rounded()))%") }
        if let p = u.sevenDayUsed { parts.append("Wk \(Int(p.rounded()))%") }
        if let p = u.primaryUsed { parts.append("\(u.primaryMeterLabel) \(Int(p.rounded()))%") }
        if let p = u.secondaryUsed { parts.append("\(u.secondaryMeterLabel) \(Int(p.rounded()))%") }
        if let spend = model.trackedAPISpend(for: u) {
            parts.append("$\(spend.formatted(.number.precision(.fractionLength(2))))")
        }
        return parts.isEmpty ? u.displayName : "\(u.displayName) \(parts.joined(separator: " · "))"
    }

    @ViewBuilder
    private func sessionChipButton(_ s: SessionInfo) -> some View {
        // Same rename-outside-Button, attention, focus-outline, hover and
        // context-menu treatment as sessionRowButton above.
        Group {
            if renamingID == s.id {
                sessionChip(s)
            } else {
                Button { model.focusSession(s) } label: {
                    sessionChip(s)
                }
                .buttonStyle(.plain)
                .disabled(s.connected && s.slot == nil && !s.backlogged)
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

    /// One-line ticker chip: slot · state · name · elapsed — everything a
    /// glance needs, nothing else. The context meter survives only as a
    /// hairline under the chip (and still yields to the compact-rows
    /// toggle); stats and model badges stay exclusive to vertical rows.
    /// Same stale/compacting/dimmed and budget-warning heuristics as
    /// sessionRow — see that function and MenuContentView for the rationale.
    private func sessionChip(_ s: SessionInfo) -> some View {
        let overBudget = model.isOverBudget(s)
        let stale = model.isStale(s)
        let displayState: AgentState = stale ? .idle : s.state
        let dimmed = stale || s.state == .compacting || !s.connected || s.pendingReopen
        let swatchColor = overBudget ? budgetWarningColor : (model.styles[displayState] ?? defaultStyle(displayState)).color
        let meterFraction = model.compactWidgetRows ? nil
            : s.contextFraction(kindOverride: model.contextWindowOverride(for: s.kind))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(s.slot.map(String.init) ?? "—")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                if s.pendingReopen {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 8)).foregroundStyle(.secondary)
                        .help("Reopening — waiting for the resumed agent to reconnect")
                } else if !s.connected {
                    FocalPointMark(color: .secondary, assetName: "focalpoint-disconnected")
                        .frame(width: 10, height: 10)
                        .help("Disconnected — no update in a while. Click to try to reopen its terminal, or dismiss it.")
                } else {
                    StateSwatch(state: displayState, color: swatchColor, size: 8)
                        .help(stale ? "No update in a while — shown as idle since the agent may have died without a clean shutdown"
                              : s.state == .compacting ? "Compacting — momentarily between session identities, not agent activity"
                              : "")
                }
                SessionTitleField(session: s, model: model,
                                  editingID: $renamingID, font: .system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
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
            .padding(.horizontal, 7)
            .padding(.top, 4)
            .padding(.bottom, meterFraction != nil ? 2 : 4)
            if let fraction = meterFraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    GeometryReader { geo in
                        Capsule().fill(swatchColor.opacity(0.7))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 2.5)
                .padding(.horizontal, 7)
                .padding(.bottom, 3)
            }
        }
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
            if hasStats, !model.compactWidgetRows {
                HStack {
                    Spacer()
                    SessionStatsView(stats: s.stats, visible: model.visibleStats)
                }
                .padding(.trailing, 1)
            }
            // Shown whenever data is available, unless Compact Rows is on —
            // it's a hairline bar, not a badge, so it doesn't compete for the
            // row's horizontal space. Leading inset matches where the stat
            // badge icons actually start (the slot number above is a plain
            // centered Text, not a filled circle, so it has a few points of
            // built-in inset the meter otherwise lacks) — without it the
            // meter reads as starting a touch too far left of everything
            // above it.
            if !model.compactWidgetRows, let tokens = s.contextTokens {
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

// MARK: - Corner resize grip (width only)

/// Borderless panels get no resize chrome from AppKit (a `.borderless`
/// window has no frame view to hit-test), so the widget ships its own grip
/// in the bottom-right corner. The grip is deliberately width-only: height
/// always fits the content, which is what keeps sessions arriving/leaving
/// from fighting a pinned frame (dead space, clipped rows). Like
/// WindowDragHandle, the work happens in a plain NSView for the same reason
/// SwiftUI gestures were abandoned for window dragging (see the comment
/// above): a direct mouseDragged → setFrame loop is tracked entirely
/// against screen coordinates, with no layout feedback. Live deltas go to
/// `onLiveResize` (in-memory, keeps the SwiftUI root frame pinned to the
/// dragged width so the clear window background never shows a gap); only
/// `onCommit` (mouse-up) persists. `onDragChanged` tells the window
/// controller a grip drag is in flight so mid-drag content refits stay
/// pinned to the same top-left corner the grip uses.
private struct ResizeGripView: NSViewRepresentable {
    let orientation: DesktopWidgetOrientation
    let onLiveResize: (CGFloat) -> Void
    let onCommit: (CGFloat) -> Void
    let onDragChanged: (Bool) -> Void

    final class GripView: NSView {
        var orientation: DesktopWidgetOrientation = .vertical
        var onLiveResize: ((CGFloat) -> Void)?
        var onCommit: ((CGFloat) -> Void)?
        var onDragChanged: ((Bool) -> Void)?
        private var dragStartMouseX: CGFloat?
        private var dragStartWidth: CGFloat = 0

        // y-down drawing (bottom-right corner = maxX/maxY). This view
        // handles its own mouse events and must stay out of
        // isMovableByWindowBackground's way.
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func draw(_ dirtyRect: NSRect) {
            // Three vertical ticks: a width-only affordance (there is no
            // vertical drag, so no diagonal-lines glyph).
            let path = NSBezierPath()
            path.lineWidth = 1.2
            path.lineCapStyle = .round
            for i in 0..<3 {
                let x = bounds.maxX - 3 - CGFloat(i) * 3.5
                path.move(to: NSPoint(x: x, y: bounds.maxY - 3))
                path.line(to: NSPoint(x: x, y: bounds.maxY - 9.5))
            }
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            dragStartMouseX = NSEvent.mouseLocation.x
            dragStartWidth = window.frame.width
            onDragChanged?(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window, let startX = dragStartMouseX else { return }
            let width = min(max(dragStartWidth + NSEvent.mouseLocation.x - startX,
                                orientation.minWidgetWidth),
                            orientation.maxWidgetWidth)
            var frame = window.frame
            guard width != frame.width else { return }
            frame.size.width = width  // left edge and height stay put
            window.setFrame(frame, display: true)
            onLiveResize?(width)
        }

        override func mouseUp(with event: NSEvent) {
            if let window { onCommit?(window.frame.width) }
            dragStartMouseX = nil
            onDragChanged?(false)
        }
    }

    func makeNSView(context: Context) -> GripView {
        let view = GripView()
        view.orientation = orientation
        view.onLiveResize = onLiveResize
        view.onCommit = onCommit
        view.onDragChanged = onDragChanged
        return view
    }

    func updateNSView(_ nsView: GripView, context: Context) {
        nsView.orientation = orientation
        nsView.onLiveResize = onLiveResize
        nsView.onCommit = onCommit
        nsView.onDragChanged = onDragChanged
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

    /// Last frame we've accounted for, so windowDidResize can tell which
    /// edges moved; see that method for why.
    private var lastFrame: NSRect?
    /// True while the corner grip is being dragged; its own math pins the
    /// left edge, and mid-drag content refits follow the same anchor.
    private var gripResizing = false

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
            // Backlog-only is storage, not activity: parked sessions leave
            // the aggregate/attention routing daemon-side, and a widget
            // showing nothing but the backlog shouldn't keep itself on
            // screen. Disconnected rows still count — that's real work lost.
            setVisible(aggregate != .idle || sessions.contains { !$0.backlogged } || hasRelaunchStatus)
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
            onQuit: { NSApp.terminate(nil) },
            onGripDragChanged: { [weak self] in self?.gripResizing = $0 }
        )
        p.contentViewController = NSHostingController(rootView: view)
        panel = p
        positionInitially()
        lastFrame = p.frame
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
        guard let p = panel else { return }
        persistPosition()
        lastFrame = p.frame
    }

    /// AppKit re-fits a contentViewController-driven window from its origin
    /// (bottom-left), so every content-driven resize — sessions appearing or
    /// disappearing, a context meter arriving, an orientation flip, a width
    /// reset — used to move the widget's *other* three edges, making it
    /// visibly jump against whatever screen edge it's parked on. Instead,
    /// pin the edges the widget is parked nearest: a widget hugging the
    /// top-right grows downward and leftward (like a dropdown), one near the
    /// bottom grows upward, etc. Grip drags self-anchor (left edge pinned by
    /// construction), so the grip's own setFrame passes through here as a
    /// no-op; the flag only matters for content refits interleaved with a
    /// drag.
    func windowDidResize(_ notification: Notification) {
        guard let p = panel else { return }
        let resized = p.frame
        guard let old = lastFrame, old.size != resized.size else {
            lastFrame = resized
            return
        }
        let pinTop: Bool
        let pinRight: Bool
        if gripResizing {
            pinTop = true
            pinRight = false
        } else if let vf = (p.screen ?? NSScreen.main)?.visibleFrame {
            pinTop = abs(resized.maxY - vf.maxY) <= abs(resized.minY - vf.minY)
            pinRight = abs(resized.maxX - vf.maxX) <= abs(resized.minX - vf.minX)
        } else {
            pinTop = true
            pinRight = false
        }
        // Bottom/left pinning needs no correction (AppKit already kept that
        // origin corner); only pull the frame back for top/right.
        var adjusted = resized
        if pinTop { adjusted.origin.y = old.maxY - resized.height }
        if pinRight { adjusted.origin.x = old.maxX - resized.width }
        if adjusted.origin != resized.origin {
            p.setFrame(adjusted, display: true)
            persistPosition()
        }
        lastFrame = adjusted
    }
}
