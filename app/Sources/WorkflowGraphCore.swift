// FocalPoint menu-bar app — workflow graph model and layered layout.
//
// This file deliberately uses Foundation only so the graph derivation and
// layout can be tested without constructing SwiftUI views or connecting to
// focalpointd. The input is a small value type (`WorkflowGraphInput`) so the
// launcher's validated FormationPackage and the editor's in-progress
// EditableFormation draft render through the exact same code path — including
// drafts that are momentarily invalid (a dangling `after` while the human is
// mid-rename must still draw something honest, never crash or loop).
// MIT License.

import Foundation
import CoreGraphics

// MARK: - Input snapshot

/// Everything the graph needs, decoupled from where it was loaded from.
/// `rootRoles` is the single-phase [[role]] form; `phases` is the phased
/// form. Exactly one is nonempty (mirroring the schema's either/or rule).
struct WorkflowGraphInput: Equatable {
    struct Role: Equatable {
        let id: String
        let name: String
        let type: String
        let kind: String             // "worker" | "orchestrator"
        let prep: String?
        let phaseName: String?
        let fanoutMaximum: Int?
        let fanoutSource: String?    // earlier role whose output names slices
    }

    struct Phase: Equatable {
        let id: String
        let name: String
        let after: String?
        let gate: FormationGateSummary
        let roles: [Role]
    }

    let name: String
    let rootRoles: [Role]
    let phases: [Phase]
    /// Subtitle under the orchestrator node, e.g. "Claude Code · opus" from a
    /// reviewed preflight. Nil shows a plain "Launched by FocalPoint".
    var orchestratorDetail: String?
    /// Per-role detail overlay (role id -> "Provider · model"), from the
    /// preflight's reviewed assignments. Absent ids render type/prep only.
    var roleDetails: [String: String] = [:]
}

// MARK: - Graph model

enum WorkflowGraphNodeKind: String, Equatable {
    case orchestrator   // the one agent the app launches directly
    case role           // fixed crew member
    case fanout         // bounded, plan-authored expansion placeholder
}

struct WorkflowGraphNode: Identifiable, Equatable {
    let id: String
    let kind: WorkflowGraphNodeKind
    let title: String
    let typeName: String
    /// Reviewed "Provider · model" when available, else the prep note.
    let detail: String?
    /// Owning phase name; nil only for the orchestrator root.
    let phaseName: String?
    let isOrchestratorKind: Bool
    let fanoutMaximum: Int?
    /// 0 is the orchestrator column; phase columns start at 1.
    let layer: Int
    /// Stacking order within the layer (top to bottom). Assigned by layout.
    var row: Int
    /// Assigned by layout; `.zero` before `WorkflowGraphModel.make` finishes.
    var frame: CGRect
}

enum WorkflowGraphEdgeKind: String, Equatable {
    case launch         // orchestrator -> node in a depth-0 phase
    case sequence       // barrier: node in the after-phase -> node in the dependent phase
    case fanoutSource   // plan role -> fan-out node (provenance of slice text)
}

struct WorkflowGraphEdge: Equatable {
    let from: String
    let to: String
    let kind: WorkflowGraphEdgeKind
}

/// A phase column header: name plus its entry gate.
struct WorkflowGraphBand: Identifiable, Equatable {
    let id: String
    let name: String
    let gate: FormationGateSummary
    let layer: Int
    let nodeIDs: [String]
    let headerFrame: CGRect
}

struct WorkflowGraph: Equatable {
    let nodes: [WorkflowGraphNode]
    let edges: [WorkflowGraphEdge]
    let bands: [WorkflowGraphBand]
    let layerCount: Int
    let contentSize: CGSize

    func node(id: String) -> WorkflowGraphNode? {
        nodes.first { $0.id == id }
    }
}

// MARK: - Layout metrics

enum WorkflowGraphLayout {
    static let nodeWidth: CGFloat = 168
    static let nodeHeight: CGFloat = 58
    static let horizontalGap: CGFloat = 56
    static let verticalGap: CGFloat = 12
    static let bandHeaderHeight: CGFloat = 18
    static let bandHeaderGap: CGFloat = 6
    static let padding: CGFloat = 6
}

// MARK: - Derivation + layout

enum WorkflowGraphModel {

    static let orchestratorNodeID = "orchestrator"

    static func make(input: WorkflowGraphInput) -> WorkflowGraph {
        // Normalize the single-phase [[role]] form into one synthetic phase,
        // matching the "main" phase name the daemon assignment ledger uses.
        let phases: [WorkflowGraphInput.Phase] = input.phases.isEmpty
            ? [WorkflowGraphInput.Phase(id: "main:0", name: "main", after: nil,
                                        gate: .authorized, roles: input.rootRoles)]
            : input.phases

        let depthByPhase = phaseDepths(phases)

        // Explicit (layer, manifest index) ordering — Swift's sort is not
        // guaranteed stable, and column order must match the manifest.
        let pending: [(phase: WorkflowGraphInput.Phase, layer: Int)] = phases.enumerated()
            .map { (phase: $0.element, layer: depthByPhase[$0.element.name, default: 0] + 1, index: $0.offset) }
            .sorted { lhs, rhs in
                lhs.layer != rhs.layer ? lhs.layer < rhs.layer : lhs.index < rhs.index
            }
            .map { ($0.phase, $0.layer) }

        var nodes: [WorkflowGraphNode] = []
        var bands: [WorkflowGraphBand] = []
        var edges: [WorkflowGraphEdge] = []
        var nodeIDByRoleName: [String: String] = [:]

        nodes.append(WorkflowGraphNode(
            id: orchestratorNodeID, kind: .orchestrator, title: "Orchestrator",
            typeName: "workflow-orchestrator",
            detail: input.orchestratorDetail ?? "Launched by FocalPoint",
            phaseName: nil, isOrchestratorKind: true, fanoutMaximum: nil,
            layer: 0, row: 0, frame: .zero   // positioned below
        ))

        for entry in pending {
            var nodeIDs: [String] = []
            for (roleIndex, role) in entry.phase.roles.enumerated() {
                let kind: WorkflowGraphNodeKind = role.fanoutMaximum == nil ? .role : .fanout
                let id = "role:\(role.id)"
                nodeIDs.append(id)
                if nodeIDByRoleName[role.name] == nil { nodeIDByRoleName[role.name] = id }
                nodes.append(WorkflowGraphNode(
                    id: id, kind: kind, title: role.name, typeName: role.type,
                    detail: input.roleDetails[role.id] ?? role.prep,
                    phaseName: entry.phase.name,
                    isOrchestratorKind: role.kind == "orchestrator",
                    fanoutMaximum: role.fanoutMaximum,
                    layer: entry.layer, row: roleIndex, frame: .zero
                ))
            }
            bands.append(WorkflowGraphBand(
                id: "band:\(entry.phase.id)", name: entry.phase.name,
                gate: entry.phase.gate, layer: entry.layer, nodeIDs: nodeIDs,
                headerFrame: .zero
            ))
        }

        // Edges. Launch edges reach every depth-0 phase; a barrier between
        // phases Q -> P connects every node pair (phases are whole-phase
        // barriers, and the bundled catalog's widest phase is four roles).
        let nodesByPhase = Dictionary(grouping: nodes, by: { $0.phaseName })
        for band in bands where band.layer == 1 {
            for id in band.nodeIDs {
                edges.append(WorkflowGraphEdge(from: orchestratorNodeID, to: id, kind: .launch))
            }
        }
        for phase in phases {
            guard let after = phase.after,
                  let sources = nodesByPhase[after]?.map(\.id),
                  let targets = nodesByPhase[phase.name]?.map(\.id) else { continue }
            for source in sources {
                for target in targets {
                    edges.append(WorkflowGraphEdge(from: source, to: target, kind: .sequence))
                }
            }
        }
        // Fan-out provenance replaces the plain barrier edge between the same
        // pair — it is strictly more specific about what flows where.
        var fanoutPairs: Set<String> = []
        for phase in phases {
            for role in phase.roles {
                guard role.fanoutMaximum != nil, let source = role.fanoutSource,
                      !source.isEmpty,
                      let sourceID = nodeIDByRoleName[source] else { continue }
                let targetID = "role:\(role.id)"
                fanoutPairs.insert("\(sourceID)->\(targetID)")
                edges.append(WorkflowGraphEdge(from: sourceID, to: targetID, kind: .fanoutSource))
            }
        }
        if !fanoutPairs.isEmpty {
            edges.removeAll { edge in
                edge.kind == .sequence && fanoutPairs.contains("\(edge.from)->\(edge.to)")
            }
        }

        return layout(nodes: nodes, edges: edges, bands: bands)
    }

    /// Depth of each phase by name: 0 when it has no `after`, else the length
    /// of its after-chain. The validator guarantees earlier-only, acyclic
    /// references, but editor drafts can violate that mid-edit, so resolution
    /// walks at most phaseCount hops — a dangling or cyclic `after` still
    /// draws (one column right per resolved hop), never loops or crashes.
    private static func phaseDepths(_ phases: [WorkflowGraphInput.Phase]) -> [String: Int] {
        let afterByName = Dictionary(phases.map { ($0.name, $0.after) },
                                     uniquingKeysWith: { first, _ in first })
        var depths: [String: Int] = [:]
        for phase in phases {
            var depth = 0
            var current: String? = phase.after
            var hops = 0
            while let name = current, hops < phases.count {
                depth += 1
                hops += 1
                current = afterByName[name] ?? nil
            }
            depths[phase.name] = depth
        }
        return depths
    }

    /// Column-per-layer layout. Each layer stacks its phase groups (band
    /// header above each group) and is centered vertically against the
    /// tallest layer, so single-column formations don't hug the top.
    private static func layout(nodes: [WorkflowGraphNode], edges: [WorkflowGraphEdge],
                               bands: [WorkflowGraphBand]) -> WorkflowGraph {
        let layerCount = (nodes.map(\.layer).max() ?? 0) + 1
        var bandsByLayer: [Int: [WorkflowGraphBand]] = [:]
        for band in bands { bandsByLayer[band.layer, default: []].append(band) }
        var nodesByLayer: [Int: [WorkflowGraphNode]] = [:]
        for node in nodes { nodesByLayer[node.layer, default: []].append(node) }

        // Height of each layer's stack (headers + nodes).
        func layerHeight(_ layer: Int) -> CGFloat {
            if layer == 0 {
                return WorkflowGraphLayout.nodeHeight
            }
            let nodeCount = CGFloat(nodesByLayer[layer, default: []].count)
            let bandCount = CGFloat(bandsByLayer[layer, default: []].count)
            guard nodeCount > 0 else { return 0 }
            return bandCount * (WorkflowGraphLayout.bandHeaderHeight + WorkflowGraphLayout.bandHeaderGap)
                + nodeCount * WorkflowGraphLayout.nodeHeight
                + max(nodeCount - 1, 0) * WorkflowGraphLayout.verticalGap
        }
        let totalHeight = (0..<layerCount).map(layerHeight).max() ?? 0

        var positioned: [WorkflowGraphNode] = []
        var positionedBands: [WorkflowGraphBand] = []
        for layer in 0..<layerCount {
            let x = WorkflowGraphLayout.padding
                + CGFloat(layer) * (WorkflowGraphLayout.nodeWidth + WorkflowGraphLayout.horizontalGap)
            var cursor = (totalHeight - layerHeight(layer)) / 2 + WorkflowGraphLayout.padding
            if layer == 0 {
                for var node in nodesByLayer[0, default: []] {
                    node.frame = CGRect(x: x, y: cursor,
                                        width: WorkflowGraphLayout.nodeWidth,
                                        height: WorkflowGraphLayout.nodeHeight)
                    positioned.append(node)
                }
                continue
            }
            var row = 0
            for band in bandsByLayer[layer, default: []] {
                let header = CGRect(x: x, y: cursor, width: WorkflowGraphLayout.nodeWidth,
                                    height: WorkflowGraphLayout.bandHeaderHeight)
                positionedBands.append(WorkflowGraphBand(
                    id: band.id, name: band.name, gate: band.gate, layer: band.layer,
                    nodeIDs: band.nodeIDs, headerFrame: header
                ))
                cursor += WorkflowGraphLayout.bandHeaderHeight + WorkflowGraphLayout.bandHeaderGap
                for nodeID in band.nodeIDs {
                    guard var node = nodesByLayer[layer, default: []].first(where: { $0.id == nodeID }) else { continue }
                    node.row = row
                    node.frame = CGRect(x: x, y: cursor,
                                        width: WorkflowGraphLayout.nodeWidth,
                                        height: WorkflowGraphLayout.nodeHeight)
                    positioned.append(node)
                    row += 1
                    cursor += WorkflowGraphLayout.nodeHeight + WorkflowGraphLayout.verticalGap
                }
            }
        }

        let width = WorkflowGraphLayout.padding * 2
            + CGFloat(layerCount) * WorkflowGraphLayout.nodeWidth
            + CGFloat(max(layerCount - 1, 0)) * WorkflowGraphLayout.horizontalGap
        return WorkflowGraph(
            nodes: positioned, edges: edges, bands: positionedBands,
            layerCount: layerCount,
            contentSize: CGSize(width: width, height: totalHeight + WorkflowGraphLayout.padding * 2)
        )
    }
}

// MARK: - FormationPackage conversion

extension FormationPackage {
    /// Graph input from a validated manifest. Role ids are the manifest's
    /// stable summary ids, so a preflight's reviewed assignments key onto
    /// them directly.
    var graphInput: WorkflowGraphInput {
        func role(_ summary: FormationRoleSummary) -> WorkflowGraphInput.Role {
            WorkflowGraphInput.Role(
                id: summary.id, name: summary.name, type: summary.type,
                kind: summary.kind, prep: summary.prep, phaseName: summary.phaseName,
                fanoutMaximum: summary.fanoutMaximum, fanoutSource: summary.fanoutSource
            )
        }
        return WorkflowGraphInput(
            name: name,
            rootRoles: roles.map(role),
            phases: phases.map { phase in
                WorkflowGraphInput.Phase(
                    id: phase.id, name: phase.name, after: phase.after,
                    gate: phase.gate, roles: phase.roles.map(role)
                )
            }
        )
    }
}
