import Foundation

// Workflow graph model/layout tests. Runs against the real bundled catalog
// (read-only) loaded through the same parser and validator the launcher
// trusts, with the enforcement check stubbed so results never depend on the
// host's actual ~/.config/focalpoint contents. Nothing here writes to user
// configuration.
//
// Build & run (from the repo root):
//   swiftc -o /tmp/WorkflowGraphCoreTests \
//       app/Tests/WorkflowGraphCoreTests.swift \
//       app/Sources/WorkflowFormationCore.swift \
//       app/Sources/WorkflowLaunchPreflightCore.swift \
//       app/Sources/WorkflowGraphCore.swift \
//   && /tmp/WorkflowGraphCoreTests

@main
enum WorkflowGraphCoreTests {
    static func main() {
        bundledCatalogLoadsAndGraphs()
        boundedDeliveryGraph()
        riskReviewGraph()
        singlePhaseFormGraph()
        discoveryPlanningGraph()
        forestPhasesShareALayer()
        danglingAndCyclicAfterStillRender()
        roleDetailOverlay()
        validatorSpotChecks()
        print("WorkflowGraphCoreTests: passed")
    }

    // MARK: Helpers

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError("check failed: \(message)") }
    }

    /// packages/workflows inside the repo, derived from this file's path.
    /// FOCALPOINT_PACKAGES_DIR overrides it (e.g. when compiled from
    /// elsewhere). Read-only: tests never mutate the catalog.
    private static func bundledWorkflowsDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["FOCALPOINT_PACKAGES_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appendingPathComponent("workflows", isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // app/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("packages/workflows", isDirectory: true)
    }

    private static func loadPackage(_ name: String) -> FormationPackage {
        let directory = bundledWorkflowsDirectory().appendingPathComponent(name, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("formation.toml")
        guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            fatalError("cannot read \(manifestURL.path)")
        }
        guard case .success(let root) = TomlParser.parse(text) else {
            fatalError("\(name): TOML parse failed")
        }
        // The launcher's enforcement check reads the host's agent config;
        // tests stub it to nil so results are host-independent.
        switch FormationManifestValidator.validate(root: root, directory: directory,
                                                   enforcedTierReason: { _ in nil }) {
        case .failure(let error):
            fatalError("\(name): bundled manifest must validate — \(error.message)")
        case .success(let package):
            return package
        }
    }

    /// Invariants every bundled formation's graph must satisfy.
    private static func checkLayoutInvariants(_ graph: WorkflowGraph, context: String) {
        let orchestrator = graph.node(id: WorkflowGraphModel.orchestratorNodeID)
        check(orchestrator != nil && orchestrator!.layer == 0, "\(context): orchestrator at layer 0")
        for edge in graph.edges {
            check(graph.node(id: edge.from) != nil && graph.node(id: edge.to) != nil,
                  "\(context): edge \(edge.from)->\(edge.to) resolves to real nodes")
        }
        for node in graph.nodes {
            check(node.frame.width == WorkflowGraphLayout.nodeWidth, "\(context): node width")
            check(node.frame.minX >= 0 && node.frame.maxX <= graph.contentSize.width
                  && node.frame.minY >= 0 && node.frame.maxY <= graph.contentSize.height,
                  "\(context): node \(node.title) inside content size")
        }
        for layer in 0..<graph.layerCount {
            let column = graph.nodes.filter { $0.layer == layer }.sorted { $0.frame.minY < $1.frame.minY }
            check(column.allSatisfy { $0.frame.minX == column.first?.frame.minX },
                  "\(context): layer \(layer) shares one x")
            for (index, node) in column.enumerated() {
                check(node.row == index, "\(context): layer \(layer) rows ordered top to bottom")
                if index > 0 {
                    check(node.frame.minY >= column[index - 1].frame.maxY,
                          "\(context): layer \(layer) nodes never overlap")
                }
            }
        }
        for band in graph.bands {
            check(!band.nodeIDs.isEmpty, "\(context): band \(band.name) has nodes")
            for id in band.nodeIDs {
                check(graph.node(id: id)?.layer == band.layer,
                      "\(context): band \(band.name) nodes live in its layer")
            }
        }
    }

    private static func edges(_ graph: WorkflowGraph, kind: WorkflowGraphEdgeKind)
        -> [WorkflowGraphEdge]
    {
        graph.edges.filter { $0.kind == kind }
    }

    // MARK: Bundled catalog

    private static func bundledCatalogLoadsAndGraphs() {
        let fm = FileManager.default
        let directory = bundledWorkflowsDirectory()
        let names = (try? fm.contentsOfDirectory(atPath: directory.path))?
            .filter { name in
                var isDirectory: ObjCBool = false
                return fm.fileExists(atPath: directory.appendingPathComponent(name).path,
                                     isDirectory: &isDirectory) && isDirectory.boolValue
            }
            .sorted() ?? []
        check(names.count >= 7, "bundled catalog present (\(names.count) formations)")
        for name in names {
            let graph = WorkflowGraphModel.make(input: loadPackage(name).graphInput)
            check(graph.nodes.count >= 2, "\(name): at least orchestrator + one role")
            check(graph.bands.count == max(1, loadPackage(name).phaseCount),
                  "\(name): one band per phase (or one for the single-phase form)")
            checkLayoutInvariants(graph, context: name)
        }
    }

    private static func boundedDeliveryGraph() {
        let package = loadPackage("bounded-delivery")
        let graph = WorkflowGraphModel.make(input: package.graphInput)

        check(graph.layerCount == 4, "bounded-delivery: orchestrator + 3 phase columns")
        check(graph.bands.map(\.name) == ["plan", "implement", "review"],
              "bounded-delivery: bands in manifest order")
        check(graph.bands.map(\.gate) == [.authorized, .confirm, .auto],
              "bounded-delivery: gates surface per phase")

        let fanout = graph.nodes.first { $0.kind == .fanout }
        check(fanout?.fanoutMaximum == 4, "bounded-delivery: fan-out ceiling 4")
        check(fanout?.typeName == "implementer", "bounded-delivery: fan-out type")
        check(fanout?.phaseName == "implement", "bounded-delivery: fan-out phase")

        let planner = graph.nodes.first { $0.title == "planner" }
        check(planner != nil, "bounded-delivery: planner node")
        let fanoutEdges = edges(graph, kind: .fanoutSource)
        check(fanoutEdges.count == 1
              && fanoutEdges.first?.from == planner?.id
              && fanoutEdges.first?.to == fanout?.id,
              "bounded-delivery: plan role feeds the fan-out")
        // The planner -> fan-out pair is provenance, not a plain barrier edge.
        check(!edges(graph, kind: .sequence).contains {
            $0.from == planner?.id && $0.to == fanout?.id
        }, "bounded-delivery: fan-out provenance replaces the barrier edge")

        check(edges(graph, kind: .launch).count == 1, "bounded-delivery: one launch edge")
        check(edges(graph, kind: .sequence).count == 3,
              "bounded-delivery: fan-out barrier fans into the three review lanes")
    }

    private static func riskReviewGraph() {
        let graph = WorkflowGraphModel.make(input: loadPackage("risk-review").graphInput)
        check(graph.layerCount == 4, "risk-review: orchestrator + 3 phase columns")
        let reviewNodes = graph.nodes.filter { $0.phaseName == "review" }
        check(reviewNodes.count == 4, "risk-review: four parallel review lanes")
        check(reviewNodes.allSatisfy { $0.layer == 2 }, "risk-review: lanes share a column")
        check(edges(graph, kind: .launch).count == 1, "risk-review: one launch edge")
        check(edges(graph, kind: .sequence).count == 8,
              "risk-review: 1x4 in, 4x1 out across the barriers")
    }

    private static func singlePhaseFormGraph() {
        let package = loadPackage("review-fanout")
        check(package.phaseCount == 0, "review-fanout: single-phase form")
        let graph = WorkflowGraphModel.make(input: package.graphInput)
        check(graph.layerCount == 2, "review-fanout: orchestrator + one crew column")
        check(graph.bands.count == 1 && graph.bands[0].name == "main"
              && graph.bands[0].gate == .authorized,
              "review-fanout: synthetic 'main' band is authorized")
        check(edges(graph, kind: .launch).count == 5,
              "review-fanout: orchestrator launches all five roles")
        check(graph.nodes.contains { $0.isOrchestratorKind && $0.kind == .role },
              "review-fanout: the crew's own orchestrator role is flagged")
    }

    private static func discoveryPlanningGraph() {
        let graph = WorkflowGraphModel.make(input: loadPackage("discovery-planning").graphInput)
        check(graph.layerCount == 3, "discovery-planning: orchestrator + 2 columns")
        check(edges(graph, kind: .launch).count == 2,
              "discovery-planning: both scouts launch together")
        check(edges(graph, kind: .sequence).count == 2,
              "discovery-planning: both scouts feed the planner")
    }

    // MARK: Hand-built inputs

    private static func role(_ id: String, _ name: String, phase: String? = nil,
                             fanoutMaximum: Int? = nil, fanoutSource: String? = nil)
        -> WorkflowGraphInput.Role
    {
        WorkflowGraphInput.Role(id: id, name: name, type: "implementer", kind: "worker",
                                prep: nil, phaseName: phase,
                                fanoutMaximum: fanoutMaximum, fanoutSource: fanoutSource)
    }

    private static func phase(_ name: String, after: String?, gate: FormationGateSummary = .auto,
                              roles: [WorkflowGraphInput.Role]) -> WorkflowGraphInput.Phase {
        WorkflowGraphInput.Phase(id: "\(name):0", name: name, after: after,
                                 gate: gate, roles: roles)
    }

    /// Two phases may depend on the same parent (a forest, not just a chain);
    /// they must land in the same column.
    private static func forestPhasesShareALayer() {
        let input = WorkflowGraphInput(name: "forest", rootRoles: [], phases: [
            phase("root", after: nil, gate: .authorized, roles: [role("r0", "root-role", phase: "root")]),
            phase("branch-a", after: "root", roles: [role("ra", "a", phase: "branch-a")]),
            phase("branch-b", after: "root", roles: [role("rb", "b", phase: "branch-b")]),
        ])
        let graph = WorkflowGraphModel.make(input: input)
        let branchA = graph.nodes.first { $0.phaseName == "branch-a" }
        let branchB = graph.nodes.first { $0.phaseName == "branch-b" }
        check(branchA?.layer == 2 && branchB?.layer == 2, "forest: siblings share a layer")
        check(branchA?.frame.minX == branchB?.frame.minX, "forest: siblings share a column x")
        check(branchA?.frame.minY != branchB?.frame.minY, "forest: siblings stack")
        check(edges(graph, kind: .launch).count == 1, "forest: only depth-0 phases launch")
        check(edges(graph, kind: .sequence).count == 2, "forest: one barrier edge per branch")
        checkLayoutInvariants(graph, context: "forest")
    }

    /// Editor drafts can be momentarily invalid; the graph must still render
    /// deterministically instead of hanging or crashing.
    private static func danglingAndCyclicAfterStillRender() {
        let dangling = WorkflowGraphModel.make(input: WorkflowGraphInput(name: "d", rootRoles: [], phases: [
            phase("root", after: nil, gate: .authorized, roles: [role("r0", "root", phase: "root")]),
            phase("lost", after: "ghost", roles: [role("r1", "lost", phase: "lost")]),
        ]))
        check(dangling.nodes.first { $0.phaseName == "lost" }?.layer == 2,
              "dangling after still draws one column right")
        checkLayoutInvariants(dangling, context: "dangling")

        let cyclic = WorkflowGraphModel.make(input: WorkflowGraphInput(name: "c", rootRoles: [], phases: [
            phase("a", after: "b", roles: [role("ra", "a", phase: "a")]),
            phase("b", after: "a", roles: [role("rb", "b", phase: "b")]),
        ]))
        check(cyclic.nodes.count == 3, "cyclic after terminates with all nodes present")
        checkLayoutInvariants(cyclic, context: "cyclic")
    }

    /// The preflight's reviewed assignments overlay by manifest role id;
    /// unknown ids are ignored and unassigned roles keep their prep detail.
    private static func roleDetailOverlay() {
        var input = WorkflowGraphInput(name: "overlay", rootRoles: [], phases: [
            phase("only", after: nil, gate: .authorized, roles: [
                role("only:assigned:0", "assigned", phase: "only"),
                WorkflowGraphInput.Role(id: "only:plain:1", name: "plain", type: "planner",
                                        kind: "worker", prep: "worktree", phaseName: "only",
                                        fanoutMaximum: nil, fanoutSource: nil),
            ]),
        ])
        input.orchestratorDetail = "Claude Code · opus"
        input.roleDetails = ["only:assigned:0": "Codex · gpt-5.6-sol", "bogus": "ignored"]
        let graph = WorkflowGraphModel.make(input: input)
        check(graph.node(id: WorkflowGraphModel.orchestratorNodeID)?.detail == "Claude Code · opus",
              "overlay: orchestrator detail")
        check(graph.node(id: "role:only:assigned:0")?.detail == "Codex · gpt-5.6-sol",
              "overlay: assignment lands by role id")
        check(graph.node(id: "role:only:plain:1")?.detail == "worktree",
              "overlay: unassigned role keeps its prep note")
    }

    // MARK: Validator spot checks (the code path the graph tests load through)

    private static func validatorSpotChecks() {
        let fanoutAuto = """
        [formation]
        name = "bad"
        version = 1
        description = "fan-out with an auto gate must fail"

        [[phase]]
        name = "plan"
        gate = "authorized"

        [[phase.role]]
        name = "planner"
        type = "planner"

        [[phase]]
        name = "implement"
        after = "plan"
        gate = "auto"

        [phase.fanout]
        from = "planner"
        max = 2
        type = "implementer"
        cwd_root = "worktrees/"

        [escalate]
        channel_kinds = ["blocker"]
        states = ["error", "approval"]
        completion = "all-roles-done"
        """
        guard case .success(let root) = TomlParser.parse(fanoutAuto) else {
            fatalError("validator spot check: parse failed")
        }
        let directory = URL(fileURLWithPath: "/tmp/bad", isDirectory: true)
        if case .success = FormationManifestValidator.validate(
            root: root, directory: directory, enforcedTierReason: { _ in nil }
        ) {
            fatalError("validator spot check: fan-out with gate auto must be rejected")
        }

        // An enforcement refusal from the (here stubbed) host check fails the
        // manifest, so a sandbox-looking type never launches as prompt text.
        let enforced = """
        [formation]
        name = "enforced"
        version = 1
        description = "role type with an enforcement refusal"

        [[role]]
        name = "locked"
        type = "locked-down"

        [escalate]
        channel_kinds = ["blocker"]
        states = ["error", "approval"]
        completion = "all-roles-done"
        """
        guard case .success(let enforcedRoot) = TomlParser.parse(enforced) else {
            fatalError("validator spot check: enforced parse failed")
        }
        switch FormationManifestValidator.validate(
            root: enforcedRoot, directory: directory,
            enforcedTierReason: { $0 == "locked-down" ? "declares [enforced]" : nil }
        ) {
        case .success:
            fatalError("validator spot check: enforcement refusal must fail validation")
        case .failure(let error):
            check(error.message.contains("declares [enforced]"),
                  "validator spot check: refusal reason surfaces")
        }
    }
}
