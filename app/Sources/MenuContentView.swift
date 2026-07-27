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
            StateSwatch(state: model.aggregate, color: model.aggregateStyle.color, size: 13)
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
            ForEach(model.sessions) { s in
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
                        .disabled(s.slot == nil)
                    }
                }
                .hoverHighlight()
                .contextMenu {
                    Button("Rename\u{2026}") { renamingID = s.id }
                    if let cwd = s.cwd {
                        Divider()
                        Button("Open in Terminal") { model.openInTerminal(cwd) }
                        Button("Show in Finder") { model.revealInFinder(cwd) }
                        Button("Copy Working Directory") { model.copyToPasteboard(cwd) }
                    }
                    Divider()
                    Button("End Session", role: .destructive) { model.endSession(s) }
                }
                if s.id != model.sessions.last?.id {
                    Divider().padding(.leading, 44)
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
    }

    private func sessionRow(_ s: SessionInfo) -> some View {
        HStack(spacing: 10) {
            slotBadge(s.slot)
            VStack(alignment: .leading, spacing: 2) {
                SessionTitleField(session: s, model: model,
                                  editingID: $renamingID, font: .body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    // Live style — reflects the user's current color/pattern for
                    // this state, not a hardcoded color.
                    StateSwatch(state: s.state, color: (model.styles[s.state] ?? defaultStyle(s.state)).color, size: 7)
                    Text(s.state.display).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            VStack(alignment: .trailing, spacing: 3) {
                Text(s.kind).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1)
                // Re-render every tick for a live "time since last change".
                Text(elapsedString(since: s.lastChange))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .id(model.tick)
                SessionStatsView(stats: s.stats, visible: model.visibleStats, size: 9)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
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
                usageMeter(label: "Primary", percent: percent, reset: usage.primaryResetsAt)
            }
            if let percent = usage.secondaryUsed {
                usageMeter(label: "Secondary", percent: percent, reset: usage.secondaryResetsAt)
            }
        }
    }

    private func usageMeter(label: String, percent: Double, reset: Date?) -> some View {
        HStack(spacing: 7) {
            Text(label).font(.caption2).frame(width: 32, alignment: .leading)
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .tint(percent >= 90 ? .orange : .accentColor)
            Text("\(Int(percent.rounded()))%")
                .font(.caption2).monospacedDigit().frame(width: 30, alignment: .trailing)
            if let reset {
                Text("→ \(reset.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
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
