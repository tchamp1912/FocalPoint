// FocalPoint menu-bar app — dropdown content (MenuBarExtra .window style).
// Translucent (Liquid Glass on macOS 26+, NSVisualEffectView below it — see
// Glass.swift), grouped into header / session list / workflow launcher /
// footer with clear typographic hierarchy. See Materials.swift for the
// shared StateSwatch, VisualEffectView bridge, and hover helper.
// MIT License.

import SwiftUI
import AppKit

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    var onSettings: () -> Void

    /// Session currently being renamed inline, if any.
    @State private var renamingID: String?

    /// Formation-package scanner + orchestrator launcher for the "Start
    /// Workflow" row (WorkflowLauncher.swift). Owned here rather than on
    /// AppModel so the feature stays inside its own file.
    @StateObject private var workflowLauncher = WorkflowLauncherModel()

    /// Radius of the window MenuBarExtra hosts the panel in — matched so the
    /// glass shape tracks the real window edge.
    private let panelRadius: CGFloat = 11

    /// Disclosure state for the two unbounded sections, persisted so the
    /// chosen layout survives relaunch.
    @AppStorage("menuSessionsExpanded") private var sessionsExpanded = true
    @AppStorage("menuUsageExpanded") private var usageExpanded = true
    /// Measured height of the session list content — see the ScrollView note.
    @State private var sessionListContentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let status = model.managedRelaunchStatus {
                ManagedRelaunchBanner(
                    status: status,
                    onDismiss: model.dismissManagedRelaunchStatus
                )
                .padding(8)
                Divider()
            }
            if model.sessions.isEmpty {
                emptyState
            } else {
                sectionHeader(title: "Sessions",
                              count: model.sessions.count,
                              symbol: "square.grid.2x2",
                              expanded: $sessionsExpanded)
                if sessionsExpanded {
                    // The session list is the only unbounded part of this
                    // panel — it grows with however many agents are live.
                    // Everything below it (usage, the workflow launcher, the
                    // footer's Settings and Quit) is fixed chrome that must
                    // stay reachable, so the list is what scrolls once the
                    // panel would otherwise run off the bottom of the screen.
                    //
                    // The height is measured rather than left to the
                    // ScrollView: a ScrollView reports essentially no ideal
                    // height inside this self-sizing MenuBarExtra window, so
                    // `.frame(maxHeight:)` alone collapses the list to
                    // nothing. Measuring the content and pinning the frame to
                    // min(content, cap) keeps it exactly content-sized until
                    // it genuinely overflows.
                    ScrollView(.vertical) {
                        sessionList
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: SessionListHeightKey.self,
                                                           value: proxy.size.height)
                                }
                            )
                    }
                    .frame(height: min(max(sessionListContentHeight, 1), sessionListMaxHeight))
                    .scrollBounceBehavior(.basedOnSize)
                    .onPreferenceChange(SessionListHeightKey.self) { height in
                        sessionListContentHeight = height
                    }
                }
            }
            if model.showUsage {
                Divider()
                sectionHeader(title: "Usage",
                              count: model.usage.count,
                              symbol: "gauge.with.dots.needle.33percent",
                              expanded: $usageExpanded)
                if usageExpanded { usageSection }
            }
            Divider()
            WorkflowLauncherSection(launcher: workflowLauncher,
                                    daemonConnected: model.connected,
                                    targetCwd: workflowTargetCwd)
            Divider()
            footer
        }
        .frame(width: 340)
        .liquidGlass(.menuPanel, radius: panelRadius)
    }

    /// Collapsible section header. Sessions and Usage both grow without
    /// bound, so each gets an explicit disclosure the human controls rather
    /// than the panel silently getting taller. Collapsed state persists, so a
    /// human who only wants the workflow launcher keeps that layout.
    private func sectionHeader(title: String, count: Int, symbol: String,
                               expanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { expanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("\(title) · \(count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Metrics.hPad)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .help(expanded.wrappedValue ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }

    /// Ceiling for the scrolling session list, derived from the screen the
    /// menu bar is on rather than hard-coded: the panel hangs from the menu
    /// bar, so the room available is the visible frame minus this panel's own
    /// fixed chrome (header, dividers, usage, workflow launcher, footer) plus
    /// a little breathing room at the bottom of the screen. The floor keeps a
    /// couple of rows visible even on a very short display.
    private var sessionListMaxHeight: CGFloat {
        let chrome: CGFloat = 300
        guard let screen = NSScreen.main else { return 420 }
        return max(180, screen.visibleFrame.height - chrome)
    }

    /// Where a started formation runs (WORKFLOWS-PROPOSAL.md §8.2's
    /// "against the auth refactor"): the session in front of the human, else
    /// the most recently active connected session, else home. The launcher
    /// menu shows it as "Runs in …" so the target is visible before anything
    /// launches, and the orchestrator is told to confirm it when the
    /// formation plainly targets something else.
    private var workflowTargetCwd: String {
        if let id = model.focusedSessionID,
           let focused = model.sessions.first(where: { $0.id == id }),
           let cwd = focused.cwd, !cwd.isEmpty {
            return cwd
        }
        if let latest = model.sessions
            .filter({ $0.connected && !($0.cwd ?? "").isEmpty })
            .max(by: { $0.lastChange < $1.lastChange }),
           let cwd = latest.cwd {
            return cwd
        }
        return NSHomeDirectory()
    }

    // MARK: Header — aggregate + connection status

    private var header: some View {
        HStack(spacing: 10) {
            FocalPointMark(color: model.aggregateStyle.color, assetName: "focalpoint-mark-menu")
                .frame(width: 36, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("FocalPoint").font(.headline)
                Text(model.aggregate.display)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            connectionBadge
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 12)
    }

    private var connectionBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(model.connected ? "Connected" : "Offline")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(.primary.opacity(0.06)))
    }

    // MARK: Session rows

    private var sessionList: some View {
        VStack(spacing: 0) {
            if !model.activeSessions.isEmpty {
                VStack(spacing: 1) {
                    ForEach(model.activeSessions) { s in
                        sessionRowButton(s, isLastInSection: s.id == model.activeSessions.last?.id)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 6)
            }
            if !model.backlogSessions.isEmpty {
                Divider()
                backlogHeader
                VStack(spacing: 1) {
                    ForEach(model.backlogSessions) { s in
                        sessionRowButton(s, isLastInSection: s.id == model.backlogSessions.last?.id)
                    }
                }
                .padding(.bottom, 6)
                .padding(.horizontal, 6)
            }
        }
    }

    /// Section divider between the active list and parked-but-still-live
    /// sessions (PROTOCOL.md §3 backlog): out of the aggregate/attention
    /// routing and off the numbered keys, but still reporting and clickable.
    private var backlogHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("Backlog")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(model.backlogSessions.count)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 6)
    }

    /// One session row with its focus button, hover, context menu, and the
    /// trailing divider between rows (suppressed after a section's last).
    @ViewBuilder
    private func sessionRowButton(_ s: SessionInfo, isLastInSection: Bool) -> some View {
        // The row being renamed is deliberately NOT wrapped in the
        // Button: `.disabled()` propagates to every descendant, so
        // disabling the row to stop a stray click from bouncing the
        // agent would also disable the text field inside it and
        // swallow every keystroke.
        Group {
            if renamingID == s.id {
                sessionRow(s)
            } else {
                Button { model.focusSession(s) } label: {
                    sessionRow(s)
                }
                .buttonStyle(.plain)
                // A live slotless session (>12 live) has no numbered
                // key to tap; a disconnected one is still focusable by
                // id (its terminal is usually still open), so only a
                // *connected* slotless row is truly un-focusable —
                // unless it's backlogged: the daemon keeps parked
                // sessions focusable by id (PROTOCOL.md §3).
                .disabled(s.connected && s.slot == nil && !s.backlogged)
            }
        }
        .hoverHighlight()
        .contextMenu { sessionContextMenu(s) }
        if !isLastInSection {
            Divider().padding(.leading, 44)
        }
    }

    @ViewBuilder
    private func sessionContextMenu(_ s: SessionInfo) -> some View {
        Button("Rename\u{2026}") { renamingID = s.id }
        // Manual placement (PROTOCOL.md §3/§4 move-slot + swap-slots):
        // free slots move (sparse placement — the gap is the point),
        // occupied slots swap. Native drag-and-drop (`.draggable`/
        // `.dropDestination`) doesn't work inside a MenuBarExtra(.window)
        // dropdown's auxiliary panel — confirmed by testing, not just a
        // theoretical gap — so this is a menu instead of a drag gesture.
        // Offered to live, active rows only: a backlogged session holds no
        // slot until it's moved back to active, and a disconnected one no
        // longer occupies its last slot.
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
        // Backlog parking (PROTOCOL.md §3 set-session-backlogged): a parked
        // session keeps reporting and stays focusable, but releases its
        // numbered key and leaves the aggregate/attention routing. The
        // daemon only accepts live sessions, so a disconnected (tombstoned)
        // row can't be moved in either direction.
        if s.backlogged {
            Button("Move to Active") { model.setSessionBacklogged(s, false) }
                .disabled(!s.connected)
        } else {
            Button("Move to Backlog") { model.setSessionBacklogged(s, true) }
                .disabled(!s.connected)
        }
        if let cwd = s.cwd {
            Divider()
            Button("Open in Terminal") { model.openInTerminal(cwd) }
            Button("Show in Finder") { model.revealInFinder(cwd) }
            Button("Copy Working Directory") { model.copyToPasteboard(cwd) }
        }
        if model.reRegisterCommand(for: s) != nil {
            Divider()
            Button("Copy Re-register Command") {
                model.copyReRegisterCommand(for: s)
            }
            .help("Paste this into the orphaned managed agent to restore its FocalPoint registration")
        }
        Divider()
        Button("Relaunch as Managed Session") {
            model.relaunchAsManaged(s)
        }
        .disabled(!model.canRelaunchAsManaged(s))
        // "End Session" is destructive — it quits the actual agent
        // process (SIGINT→SIGTERM, so its SessionEnd teardown
        // runs). "Remove Session" is non-destructive — it just
        // drops the row from FocalPoint and leaves the agent
        // running (also the way to clear a disconnected row).
        Button("End Session", role: .destructive) { model.quitSession(s) }
        Button("Remove Session") { model.removeSession(s) }
    }

    private func sessionRow(_ s: SessionInfo) -> some View {
        let hasStats = SessionStat.allCases.contains { model.visibleStats.contains($0) && s.stats[$0] != nil }
        let overBudget = model.isOverBudget(s)
        // A session stuck "thinking"/"running"/"waiting"/"approval" past the stale
        // threshold almost always means its agent died without a clean
        // shutdown, not that it's still working — see AppModel.isStale.
        // Displayed as idle (icon, color, label) and dimmed, rather than
        // silently kept looking live indefinitely.
        let stale = model.isStale(s)
        let displayState: AgentState = stale ? .idle : s.state
        // Compacting is transient bookkeeping (PROTOCOL.md §1/§3), not agent
        // activity — dim it the same as a stale session so it reads as
        // "don't worry about this" at a glance, distinct from live states. A
        // disconnected (sweep-reaped) session is dimmed for the same reason:
        // it's kept around for recovery, not actively working.
        let dimmed = stale || s.state == .compacting || !s.connected || s.pendingReopen
        let swatchColor = overBudget ? budgetWarningColor : (model.styles[displayState] ?? defaultStyle(displayState)).color
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                slotBadge(s.slot)
                VStack(alignment: .leading, spacing: 4) {
                    // Title on its own line so it uses the full content width
                    // instead of sharing a row with the metadata column.
                    SessionTitleField(session: s, model: model,
                                      editingID: $renamingID, font: .body)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        HStack(spacing: 5) {
                            if s.pendingReopen {
                                Image(systemName: "arrow.clockwise")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .help("Reopening — waiting for the resumed agent to reconnect")
                                Text("Reopening\u{2026}")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if s.health == .unknown {
                                Image(systemName: "questionmark.circle")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .help(s.healthReason ?? s.health.display)
                                Text("Unknown")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if !s.connected {
                                FocalPointMark(color: .secondary,
                                               assetName: "focalpoint-disconnected")
                                    .frame(width: 11, height: 11)
                                    .help("Disconnected — no update in a while (often just idle past the timeout). Kept for recovery; click to try to reopen its terminal, or dismiss it.")
                                Text("Disconnected")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if s.health == .suspect {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .help(s.healthReason ?? s.health.display)
                                Text(s.health.display)
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                StateSwatch(state: displayState, color: swatchColor, size: 7)
                                Text(stale ? "Possibly stale" : s.state.display)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if overBudget {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(budgetWarningColor)
                                    .help("Over the configured token/cost budget")
                            }
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 6) {
                            orchestrationBadge(s)
                            if s.isManaged {
                                HStack(spacing: 3) {
                                    Image(systemName: "terminal.fill")
                                    Text("Managed")
                                }
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                .fixedSize()
                                .help("Managed session — FocalPoint can route attention and input to it precisely in the background")
                            }
                            Text(s.kind).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            if model.showModelBadge, let badge = s.modelBadge {
                                Text(badge).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Text(elapsedString(since: s.lastChange))
                                .font(.caption)
                                .foregroundStyle(overBudget ? budgetWarningColor : .secondary)
                                .monospacedDigit()
                                .id(model.tick)
                        }
                    }

                    if hasStats {
                        HStack {
                            Spacer(minLength: 0)
                            SessionStatsView(stats: s.stats, visible: model.visibleStats, size: 9)
                        }
                    }
                }
            }
            if let tokens = s.contextTokens {
                let kindOverride = model.contextWindowOverride(for: s.kind)
                if let fraction = s.contextFraction(kindOverride: kindOverride),
                   let window = s.effectiveContextWindow(kindOverride: kindOverride) {
                    ContextMeterView(fraction: fraction, occupancy: tokens, window: window)
                        .padding(.top, 3)
                } else if let raw = s.contextTokensDisplay {
                    Text(raw).font(.caption2).foregroundStyle(.tertiary)
                        .padding(.top, 1)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .opacity(dimmed ? 0.55 : 1)
    }

    @ViewBuilder
    private func orchestrationBadge(_ session: SessionInfo) -> some View {
        if let number = model.orchestratorNumber(for: session) {
            let count = model.managedSessionCount(for: session)
            Text("O\(number) · \(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.purple)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Capsule().fill(Color.purple.opacity(0.14)))
                .fixedSize()
                .help("Orchestrator O\(number) — manages \(count) session\(count == 1 ? "" : "s")")
        } else if let number = model.managingOrchestratorNumber(for: session),
                  let manager = model.managingOrchestrator(for: session) {
            Text("O\(number)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.purple)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .overlay(Capsule().stroke(Color.purple.opacity(0.45), lineWidth: 1))
                .fixedSize()
                .help("Managed by O\(number): \(manager.title)")
        }
    }

    private func slotBadge(_ slot: Int?) -> some View {
        Text(slot.map(String.init) ?? "—")
            .font(.system(.caption, design: .monospaced, weight: .semibold))
            .foregroundStyle(slot == nil ? .secondary : .primary)
            .frame(width: 20, height: 20)
            .background(Circle().fill(.primary.opacity(0.08)))
    }

    // MARK: Account usage

    @ViewBuilder
    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Usage", systemImage: "gauge.with.dots.needle.67percent")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !model.usage.isEmpty {
                    Text("Last known").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if model.usage.isEmpty {
                Text(model.usageSupported
                     ? "No provider usage reported yet"
                     : "Usage monitor needs a current daemon")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(model.usage) { usage in
                    usageRow(usage)
                }
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 10)
    }

    private func usageRow(_ usage: ProviderUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(usage.displayName).font(.caption).bold()
            if let percent = usage.fiveHourUsed {
                usageMeter(label: "5h", percent: percent, reset: usage.fiveHourResetsAt)
            }
            if let percent = usage.sevenDayUsed {
                usageMeter(label: "Week", percent: percent, reset: usage.sevenDayResetsAt)
            }
            if let percent = usage.primaryUsed {
                usageMeter(label: usage.primaryMeterLabel, percent: percent, reset: usage.primaryResetsAt)
            }
            if let percent = usage.secondaryUsed {
                usageMeter(label: usage.secondaryMeterLabel, percent: percent, reset: usage.secondaryResetsAt)
            }
            if let spend = model.trackedAPISpend(for: usage) {
                Text(apiSpendText(usage, spend: spend))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let input = model.trackedAPIInputTokens(for: usage),
               let output = model.trackedAPIOutputTokens(for: usage) {
                Text("API tokens \(model.apiUsageTrackingLabel): \(compactTokenCount(input)) in · \(compactTokenCount(output)) out")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func apiSpendText(_ usage: ProviderUsage, spend: Double) -> String {
        let amount = spend.formatted(.currency(code: "USD"))
        if let end = usage.apiSpendPeriodEndsAt {
            return "API spend \(amount) \(model.apiUsageTrackingEnabled ? "since reset" : usage.apiSpendPeriodLabel) · resets \(end.formatted(date: .omitted, time: .shortened))"
        }
        return "API spend \(amount) \(model.apiUsageTrackingEnabled ? "since reset" : usage.apiSpendPeriodLabel)"
    }

    private func compactTokenCount(_ value: Double) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", value / 1_000_000) :
            value >= 1_000 ? String(format: "%.1fk", value / 1_000) : String(Int(value))
    }

    private func usageMeter(label: String, percent: Double, reset: Date?) -> some View {
        UsageMeterBar(label: label, labelWidth: 32, percent: percent, reset: reset, style: .menu)
    }

    // MARK: Empty state — calm, not error-like

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("No active sessions").font(.body).foregroundStyle(.secondary)
            Text("Aggregate: \(model.aggregate.display)")
                .font(.caption2).foregroundStyle(.tertiary)
            if model.connected && !model.sessionsSupported {
                Text("Daemon reports aggregate only")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            FocalPointMark(color: model.aggregateStyle.color, assetName: "focalpoint-mark-menu")
                .frame(width: 18, height: 12)
            Button { onSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power")
            }
        }
        .liquidGlassButton()
        .font(.callout)
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 10)
    }
}

/// Carries the measured height of the session list out of the ScrollView so
/// the frame can be pinned to min(content, cap). Without a measurement the
/// ScrollView reports no ideal height in this self-sizing window and the list
/// collapses to nothing.
private struct SessionListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
