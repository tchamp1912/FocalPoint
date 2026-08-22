// FocalPoint — production SwiftUI live workflow run dashboard.
// MIT License.

import SwiftUI

struct WorkflowRunDashboardView: View {
    let snapshot: WorkflowRunDashboardSnapshot
    var actions: WorkflowRunDashboardActions = .disabled

    @State private var selectedPhaseID: String?
    @State private var pendingCommand: WorkflowRunDashboardCommand?

    private var selectedPhase: WorkflowRunPhase? {
        let target = selectedPhaseID ?? snapshot.activePhaseID ?? snapshot.phases.first?.id
        return snapshot.phases.first(where: { $0.id == target })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                phaseRail
                    .frame(minWidth: 215, idealWidth: 245, maxWidth: 290)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        summaryStrip
                        if let phase = selectedPhase {
                            phaseDetail(phase)
                        } else {
                            ContentUnavailableView("No phases reported",
                                                   systemImage: "point.3.connected.trianglepath.dotted",
                                                   description: Text("The workflow adapter has not supplied phase data."))
                                .frame(maxWidth: .infinity, minHeight: 260)
                        }
                    }
                    .padding(20)
                }
                .frame(minWidth: 540)
            }
        }
        .frame(minWidth: 820, minHeight: 570)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { repairSelection() }
        .onChange(of: snapshot.activePhaseID) { _, _ in repairSelection() }
        .onChange(of: snapshot.phases.map(\.id)) { _, _ in repairSelection() }
        .alert(confirmation?.title ?? "Confirm action",
               isPresented: Binding(get: { pendingCommand != nil },
                                    set: { if !$0 { pendingCommand = nil } })) {
            Button("Cancel", role: .cancel) { pendingCommand = nil }
            if let command = pendingCommand, let confirmation {
                Button(confirmation.confirmLabel,
                       role: confirmation.isDestructive ? .destructive : nil) {
                    perform(command)
                    pendingCommand = nil
                }
            }
        } message: {
            if let confirmation { Text(confirmation.message) }
        }
    }

    private var confirmation: WorkflowRunConfirmation? {
        pendingCommand.flatMap(WorkflowRunDashboardReducer.confirmation)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            stateSymbol(snapshot.state)
                .font(.system(size: 24, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(stateColor(snapshot.state).opacity(0.14), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(snapshot.title).font(.title2.weight(.semibold)).lineLimit(1)
                    statusPill(snapshot.state.title, color: stateColor(snapshot.state))
                }
                Text(snapshot.formationName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 18)

            if let detail = snapshot.statusDetail {
                Label(detail, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 260, alignment: .trailing)
            }

            VStack(alignment: .trailing, spacing: 3) {
                Text("Updated \(snapshot.updatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption.weight(.medium))
                Text(snapshot.updatedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var phaseRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PHASES")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(snapshot.phases.sorted(by: { $0.sequence < $1.sequence })) { phase in
                        Button {
                            selectedPhaseID = phase.id
                        } label: {
                            HStack(spacing: 10) {
                                phaseMarker(phase)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(phase.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    HStack(spacing: 5) {
                                        Text(phase.state.title)
                                        Text("•")
                                        Text(phase.gate.title)
                                    }
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .background(selectedPhase?.id == phase.id ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Phase \(phase.sequence), \(phase.name), \(phase.state.title)")
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider()
            VStack(alignment: .leading, spacing: 5) {
                timestampRow("Started", snapshot.startedAt)
                timestampRow("Finished", snapshot.finishedAt)
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var summaryStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { summaryCards }
            VStack(spacing: 10) { summaryCards }
        }
    }

    @ViewBuilder private var summaryCards: some View {
        metricCard(title: "Sessions", value: "\(snapshot.roles.count)",
                   detail: "\(snapshot.healthyRoleCount) healthy",
                   symbol: "person.2.fill", tint: .blue)
        metricCard(title: "Attention", value: "\(snapshot.attentionCount)",
                   detail: snapshot.attentionCount == 0 ? "No blockers" : "Needs review",
                   symbol: "bell.badge.fill", tint: snapshot.attentionCount == 0 ? .green : .orange)
        metricCard(title: "Cost", value: formattedCost(snapshot.costUSD),
                   detail: budgetDetail,
                   symbol: "dollarsign.circle.fill", tint: costTint)
        metricCard(title: "Context", value: formattedContext(snapshot.knownContextFraction),
                   detail: "Highest live pressure",
                   symbol: "gauge.with.dots.needle.67percent", tint: contextTint(snapshot.knownContextFraction))
    }

    private func phaseDetail(_ phase: WorkflowRunPhase) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Phase \(phase.sequence)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        statusPill(phase.state.title, color: phaseColor(phase.state))
                        Label(phase.gate.title, systemImage: gateSymbol(phase.gate))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(phase.name).font(.title3.weight(.semibold))
                    if let purpose = phase.purpose {
                        Text(purpose).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    timestampRow("Started", phase.startedAt)
                    timestampRow("Updated", phase.updatedAt)
                    timestampRow("Finished", phase.finishedAt)
                }
            }

            if !phase.actions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gate & phase controls")
                        .font(.subheadline.weight(.semibold))
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(phase.actions) { action in
                                phaseActionButton(action, phase: phase)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }

            Divider()
            let roles = snapshot.roles.filter { $0.phaseID == phase.id }
            HStack {
                Text("Roles").font(.headline)
                Text("\(roles.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            if roles.isEmpty {
                Text("No roles reported for this phase.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 22)
                    .frame(maxWidth: .infinity)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 315), spacing: 12)], spacing: 12) {
                    ForEach(roles) { role in roleCard(role) }
                }
            }
        }
    }

    private func roleCard(_ role: WorkflowRunRole) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: roleSymbol(role.state))
                    .foregroundStyle(roleColor(role.state))
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.title).font(.headline).lineLimit(1)
                    Text(role.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                statusPill(role.state.title, color: roleColor(role.state))
            }

            HStack(spacing: 12) {
                detailLabel(role.provider ?? "Provider unknown", symbol: "shippingbox")
                detailLabel(role.model ?? "Model unknown", symbol: "cpu")
            }

            healthRow(role)

            if let context = role.context {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Context pressure").font(.caption)
                        Spacer()
                        Text("\(formatCount(context.usedTokens)) / \(formatCount(context.limitTokens))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: context.fraction)
                        .tint(contextTint(context.fraction))
                    Text("\(Int((context.fraction * 100).rounded()))% used")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                unavailableMetric("Context pressure not reported")
            }

            HStack {
                if let cost = role.costUSD {
                    Label(cost.formatted(.currency(code: "USD")), systemImage: "dollarsign.circle")
                        .font(.caption.monospacedDigit())
                } else {
                    Text("Cost not reported").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(role.updatedAt.map { "Updated " + $0.formatted(.relative(presentation: .named)) } ?? "No update timestamp")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack(spacing: 8) {
                availabilityButton("Focus", symbol: "scope",
                                   availability: role.focusAvailability) {
                    handle(.focusRole(roleID: role.id), availability: role.focusAvailability)
                }
                availabilityButton("Stop", symbol: "stop.fill", role: .destructive,
                                   availability: role.stopAvailability) {
                    handle(.stopRole(roleID: role.id, roleTitle: role.title),
                           availability: role.stopAvailability)
                }
                Spacer()
                if let finished = role.finishedAt {
                    Text("Finished \(finished.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let started = role.startedAt {
                    Text("Started \(started.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5), lineWidth: 1))
    }

    private func healthRow(_ role: WorkflowRunRole) -> some View {
        HStack(spacing: 7) {
            Circle().fill(healthColor(role.health)).frame(width: 8, height: 8)
            Text("Session \(role.health.title)").font(.caption.weight(.medium))
            if let detail = role.healthDetail {
                Text("— \(detail)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let id = role.sessionID {
                Text(id).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
    }

    private func phaseActionButton(_ action: WorkflowRunPhaseAction,
                                   phase: WorkflowRunPhase) -> some View {
        Button {
            handle(.phaseAction(phaseID: phase.id, phaseName: phase.name, action: action),
                   availability: action.availability)
        } label: {
            Label(action.label, systemImage: action.emphasis == .destructive ? "exclamationmark.triangle" : "arrow.right.circle")
        }
        .buttonStyle(.bordered)
        .tint(action.emphasis == .destructive ? Color.red : Color.accentColor)
        .disabled(!action.availability.isAvailable)
        .help(action.availability.reason ?? action.detail + " Confirmation is required.")
    }

    private func availabilityButton(_ title: String, symbol: String, role: ButtonRole? = nil,
                                    availability: WorkflowRunActionAvailability,
                                    action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!availability.isAvailable)
            .help(availability.reason ?? (title == "Stop" ? "Requires confirmation" : title))
    }

    private func handle(_ command: WorkflowRunDashboardCommand,
                        availability: WorkflowRunActionAvailability) {
        switch WorkflowRunDashboardReducer.intent(for: command, availability: availability) {
        case .perform(let command): perform(command)
        case .confirm(let command): pendingCommand = command
        case .blocked: break // Disabled controls cannot normally enter this path.
        }
    }

    private func perform(_ command: WorkflowRunDashboardCommand) {
        switch command {
        case .focusRole(let roleID): actions.focusRole(roleID)
        case .stopRole(let roleID, _): actions.stopRole(roleID)
        case .phaseAction(let phaseID, _, let action): actions.performPhaseAction(phaseID, action.id)
        }
    }

    private func repairSelection() {
        if let selectedPhaseID, snapshot.phases.contains(where: { $0.id == selectedPhaseID }) { return }
        selectedPhaseID = snapshot.activePhaseID ?? snapshot.phases.first?.id
    }

    private func metricCard(title: String, value: String, detail: String,
                            symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 17, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.headline.monospacedDigit())
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 67)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
    }

    private func phaseMarker(_ phase: WorkflowRunPhase) -> some View {
        ZStack {
            Circle().fill(phaseColor(phase.state).opacity(0.16)).frame(width: 30, height: 30)
            Image(systemName: phaseSymbol(phase.state)).foregroundStyle(phaseColor(phase.state)).font(.caption.weight(.bold))
        }
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13), in: Capsule())
    }

    private func detailLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private func unavailableMetric(_ text: String) -> some View {
        Label(text, systemImage: "questionmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func timestampRow(_ label: String, _ date: Date?) -> some View {
        HStack(spacing: 5) {
            Text(label + ":").foregroundStyle(.secondary)
            Text(date?.formatted(date: .abbreviated, time: .shortened) ?? "—")
        }
        .font(.caption2.monospacedDigit())
    }

    private var budgetDetail: String {
        guard let budget = snapshot.budgetUSD else { return "No budget reported" }
        return "of \(budget.formatted(.currency(code: "USD"))) budget"
    }

    private var costTint: Color {
        guard let cost = snapshot.costUSD, let budget = snapshot.budgetUSD, budget > 0 else { return .green }
        return cost / budget >= 0.9 ? .red : (cost / budget >= 0.7 ? .orange : .green)
    }

    private func formattedCost(_ value: Double?) -> String {
        value?.formatted(.currency(code: "USD")) ?? "—"
    }

    private func formattedContext(_ value: Double?) -> String {
        value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }

    private func formatCount(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func stateColor(_ state: WorkflowRunState) -> Color {
        switch state {
        case .queued: return .secondary
        case .running: return .blue
        case .waiting: return .orange
        case .blocked, .failed: return .red
        case .stopping: return .orange
        case .completed: return .green
        case .cancelled: return .secondary
        }
    }

    private func stateSymbol(_ state: WorkflowRunState) -> Image {
        Image(systemName: state == .completed ? "checkmark.circle.fill" :
              state == .failed || state == .blocked ? "exclamationmark.triangle.fill" :
              state == .running ? "bolt.circle.fill" : "circle.dotted")
    }

    private func phaseColor(_ state: WorkflowRunPhaseState) -> Color {
        switch state {
        case .pending: return .secondary
        case .ready: return .blue
        case .running: return .indigo
        case .awaitingGate: return .orange
        case .completed: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }

    private func phaseSymbol(_ state: WorkflowRunPhaseState) -> String {
        switch state {
        case .pending: return "circle"
        case .ready: return "play.fill"
        case .running: return "bolt.fill"
        case .awaitingGate: return "hand.raised.fill"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .skipped: return "forward.fill"
        }
    }

    private func gateSymbol(_ gate: WorkflowRunGateKind) -> String {
        switch gate {
        case .authorized: return "checkmark.seal"
        case .confirm: return "person.badge.key"
        case .automatic: return "gearshape.2"
        }
    }

    private func roleColor(_ state: WorkflowRunRoleState) -> Color {
        switch state {
        case .queued, .stopped: return .secondary
        case .starting, .working: return .blue
        case .waiting, .approval: return .orange
        case .completed: return .green
        case .failed, .disconnected: return .red
        }
    }

    private func roleSymbol(_ state: WorkflowRunRoleState) -> String {
        switch state {
        case .queued: return "clock"
        case .starting: return "arrow.up.circle"
        case .working: return "bolt.fill"
        case .waiting: return "hourglass"
        case .approval: return "hand.raised.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .stopped: return "stop.circle"
        case .disconnected: return "wifi.slash"
        }
    }

    private func healthColor(_ health: WorkflowRunSessionHealth) -> Color {
        switch health {
        case .healthy: return .green
        case .delayed: return .orange
        case .stale, .disconnected: return .red
        case .unknown: return .secondary
        }
    }

    private func contextTint(_ fraction: Double?) -> Color {
        guard let fraction else { return .secondary }
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return .blue
    }
}
