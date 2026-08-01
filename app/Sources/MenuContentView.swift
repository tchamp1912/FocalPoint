// FocalPoint menu-bar app — dropdown content (MenuBarExtra .window style).
// Translucent (Liquid Glass on macOS 26+, NSVisualEffectView below it — see
// Glass.swift), grouped into header / session list / footer with clear
// typographic hierarchy. See Materials.swift for the shared StateSwatch,
// VisualEffectView bridge, and hover helper.
// MIT License.

import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    var onSettings: () -> Void

    /// Session currently being renamed inline, if any.
    @State private var renamingID: String?

    /// Radius of the window MenuBarExtra hosts the panel in — matched so the
    /// glass shape tracks the real window edge.
    private let panelRadius: CGFloat = 11

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
                sessionList
            }
            if model.showUsage {
                Divider()
                usageSection
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .liquidGlass(.menuPanel, radius: panelRadius)
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
        VStack(spacing: 1) {
            ForEach(model.elevatedSessions) { s in
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
                        // *connected* slotless row is truly un-focusable.
                        .disabled(s.connected && s.slot == nil)
                    }
                }
                .hoverHighlight()
                .contextMenu {
                    Button("Rename\u{2026}") { renamingID = s.id }
                    // Manual reorder (PROTOCOL.md §3/§4 swap-slots): native
                    // drag-and-drop (`.draggable`/`.dropDestination`) doesn't
                    // work inside a MenuBarExtra(.window) dropdown's
                    // auxiliary panel — confirmed by testing, not just a
                    // theoretical gap — so this is a menu instead of a drag
                    // gesture. Only offered when this session and at least
                    // one other both hold a real slot; slotless (>12 live)
                    // sessions have nothing to swap.
                    let otherSlotted = model.sessions.filter { $0.id != s.id && $0.slot != nil }
                    if s.slot != nil, !otherSlotted.isEmpty {
                        Menu("Move to Slot") {
                            ForEach(otherSlotted) { other in
                                Button("Swap with #\(other.slot!) \u{00B7} \(other.title)") {
                                    model.swapSlots(s, other)
                                }
                            }
                        }
                    }
                    if let cwd = s.cwd {
                        Divider()
                        Button("Open in Terminal") { model.openInTerminal(cwd) }
                        Button("Show in Finder") { model.revealInFinder(cwd) }
                        Button("Copy Working Directory") { model.copyToPasteboard(cwd) }
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
                if s.id != model.elevatedSessions.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private func sessionRow(_ s: SessionInfo) -> some View {
        let hasStats = SessionStat.allCases.contains { model.visibleStats.contains($0) && s.stats[$0] != nil }
        let overBudget = model.isOverBudget(s)
        // A session stuck "thinking"/"running"/"waiting" past the stale
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
                            } else if !s.connected {
                                FocalPointMark(color: .secondary,
                                               assetName: "focalpoint-disconnected")
                                    .frame(width: 11, height: 11)
                                    .help("Disconnected — no update in a while (often just idle past the timeout). Kept for recovery; click to try to reopen its terminal, or dismiss it.")
                                Text("Disconnected")
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
            Text(usage.provider.capitalized).font(.caption).bold()
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
        }
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
