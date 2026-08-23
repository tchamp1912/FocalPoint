// FocalPoint menu-bar app — workflow graph view.
//
// Renders a formation as a left-to-right layered graph: the orchestrator the
// app launches, then one column per phase depth with the phase's roles (or
// its bounded fan-out placeholder) stacked under a gate-labeled header.
// Edges are launch (orchestrator -> first column), sequence (phase barrier),
// and fan-out provenance (plan role -> fan-out node, dashed). All derivation
// and layout live in WorkflowGraphCore.swift; this file is drawing only.
// MIT License.

import SwiftUI
import AppKit

struct WorkflowGraphView: View {
    let graph: WorkflowGraph

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                edgeCanvas
                ForEach(graph.bands) { band in
                    bandHeader(band)
                }
                ForEach(graph.nodes) { node in
                    nodeCard(node)
                }
            }
            .frame(width: graph.contentSize.width, height: graph.contentSize.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Edges

    private var edgeCanvas: some View {
        Canvas { context, _ in
            for edge in graph.edges {
                guard let source = graph.node(id: edge.from),
                      let target = graph.node(id: edge.to) else { continue }
                let from = CGPoint(x: source.frame.maxX, y: source.frame.midY)
                let to = CGPoint(x: target.frame.minX, y: target.frame.midY)
                let midX = (from.x + to.x) / 2
                var path = Path()
                path.move(to: from)
                path.addCurve(to: to,
                              control1: CGPoint(x: midX, y: from.y),
                              control2: CGPoint(x: midX, y: to.y))
                switch edge.kind {
                case .fanoutSource:
                    context.stroke(path, with: .color(.orange.opacity(0.75)),
                                   style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                case .launch:
                    context.stroke(path, with: .color(.secondary.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 1.2))
                case .sequence:
                    context.stroke(path, with: .color(.secondary.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 1.2))
                }
            }
        }
        .frame(width: graph.contentSize.width, height: graph.contentSize.height)
        .allowsHitTesting(false)
    }

    // MARK: Phase band headers

    private func bandHeader(_ band: WorkflowGraphBand) -> some View {
        HStack(spacing: 5) {
            Text(band.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            gatePill(band.gate)
        }
        .frame(width: band.headerFrame.width, height: band.headerFrame.height, alignment: .leading)
        .position(x: band.headerFrame.midX, y: band.headerFrame.midY)
        .help("\(band.name) · gate \(band.gate.title): \(band.gate.explanation)")
    }

    private func gatePill(_ gate: FormationGateSummary) -> some View {
        Label(gate.title, systemImage: gate == .confirm ? "hand.raised.fill" : "checkmark.shield")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(gate == .confirm ? .orange : .secondary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(
                Capsule().fill(gate == .confirm
                               ? Color.orange.opacity(0.14)
                               : Color.primary.opacity(0.06))
            )
    }

    // MARK: Node cards

    private func nodeCard(_ node: WorkflowGraphNode) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: symbol(for: node))
                .font(.system(size: 12))
                .foregroundStyle(iconTint(for: node))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(node.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let max = node.fanoutMaximum {
                        Text("× ≤ \(max)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
                Text(node.typeName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail = node.detail {
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .frame(width: node.frame.width, height: node.frame.height)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Metrics.rowRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.rowRadius)
                .strokeBorder(node.kind == .fanout ? Color.orange.opacity(0.45) : .clear,
                              lineWidth: 1)
        )
        .position(x: node.frame.midX, y: node.frame.midY)
        .help(helpText(for: node))
    }

    private func symbol(for node: WorkflowGraphNode) -> String {
        switch node.kind {
        case .orchestrator: return "person.badge.key"
        case .fanout: return "arrow.triangle.branch"
        case .role: return node.isOrchestratorKind ? "person.badge.key" : "person"
        }
    }

    private func iconTint(for node: WorkflowGraphNode) -> Color {
        switch node.kind {
        case .orchestrator: return .accentColor
        case .fanout: return .orange
        case .role: return .secondary
        }
    }

    private func helpText(for node: WorkflowGraphNode) -> String {
        switch node.kind {
        case .orchestrator:
            return "The one agent FocalPoint launches; it expands and sequences the crew."
        case .fanout:
            let max = node.fanoutMaximum.map { "≤ \($0)" } ?? ""
            return "Bounded fan-out (\(max) slices) of type '\(node.typeName)'. The plan chooses slice count and task text; a human gate confirms the resolved crew."
        case .role:
            var text = "\(node.title) · type '\(node.typeName)'"
            if let phase = node.phaseName { text += " · phase '\(phase)'" }
            if let detail = node.detail { text += " · \(detail)" }
            return text
        }
    }

    private var accessibilitySummary: String {
        let roles = graph.nodes.filter { $0.kind == .role }.count
        let fanouts = graph.nodes.filter { $0.kind == .fanout }.count
        var summary = "Workflow graph: \(graph.bands.count) phase column\(graph.bands.count == 1 ? "" : "s"), \(roles) role\(roles == 1 ? "" : "s")"
        if fanouts > 0 { summary += ", \(fanouts) fan-out\(fanouts == 1 ? "" : "s")" }
        return summary
    }
}

// MARK: - Conversions from the app's two formation representations

extension WorkflowGraphInput {
    /// A validated package plus (optionally) the preflight's reviewed
    /// provider/model assignments, keyed by the manifest's stable role ids.
    init(package: FormationPackage,
         orchestratorDetail: String? = nil,
         assignments: [WorkflowRoleAssignment] = []) {
        var input = package.graphInput
        input.orchestratorDetail = orchestratorDetail
        input.roleDetails = Dictionary(
            assignments.map { ($0.id, "\($0.provider.title) · \($0.model)") },
            uniquingKeysWith: { first, _ in first }
        )
        self = input
    }

    /// An editor draft. Drafts can be momentarily invalid (empty names,
    /// dangling `after`); the graph model is built to render those honestly
    /// rather than refuse — the editor's own diagnostics list the problems.
    init(draft: EditableFormation) {
        func role(_ editable: EditableRole, phase: String?) -> WorkflowGraphInput.Role {
            WorkflowGraphInput.Role(
                id: editable.id.uuidString, name: editable.name, type: editable.type,
                kind: editable.kind.rawValue, prep: editable.prep.isEmpty ? nil : editable.prep,
                phaseName: phase, fanoutMaximum: nil, fanoutSource: nil
            )
        }
        let phases: [WorkflowGraphInput.Phase] = draft.phases.enumerated().map { index, phase in
            let roles: [WorkflowGraphInput.Role]
            if phase.useFanout {
                roles = [WorkflowGraphInput.Role(
                    id: "\(phase.id.uuidString):fanout", name: "Slices from \(phase.fanout.from)",
                    type: phase.fanout.type, kind: "worker",
                    prep: "\(phase.fanout.cwdRoot) worktrees", phaseName: phase.name,
                    fanoutMaximum: phase.fanout.max, fanoutSource: phase.fanout.from
                )]
            } else {
                roles = phase.roles.map { role($0, phase: phase.name) }
            }
            return WorkflowGraphInput.Phase(
                id: phase.id.uuidString, name: phase.name, after: phase.after,
                gate: FormationGateSummary(rawValue: phase.gate.rawValue) ?? .authorized,
                roles: roles
            )
        }
        self.init(name: draft.name,
                  rootRoles: draft.roles.map { role($0, phase: nil) },
                  phases: draft.phased ? phases : [])
    }
}
