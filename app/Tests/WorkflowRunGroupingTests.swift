// Tests for WorkflowRunGrouping — compile with Protocol.swift and
// WorkflowRunGrouping.swift (see app/Tests/README pattern: standalone
// @main executable, no XCTest).
import Foundation

@main
enum WorkflowRunGroupingTests {
    static func main() {
        testPartitionsByRunID()
        testUngroupedWhenNoWorkflowMeta()
        testAggregateIsWorstState()
        testLeadPrefersOrchestrator()
        testPhasesDistinctInFirstSeenOrder()
        testDisplayNamePrettifies()
        testSingletonRunStillGroups()
        testNextAttentionMember()
        print("WorkflowRunGroupingTests: PASS")
    }

    private static func session(_ id: String, slot: Int? = nil,
                                state: AgentState = .idle,
                                run: String? = nil, workflow: String? = nil,
                                phase: String? = nil,
                                orchestratorTaskID: String? = nil,
                                orchestrationRole: String? = nil,
                                managerTaskID: String? = nil) -> SessionInfo {
        var s = SessionInfo(id: id, kind: "agent", state: state,
                            firstSeen: Date(), lastChange: Date())
        s.slot = slot
        s.workflowRunID = run
        s.workflowID = workflow
        s.workflowPhase = phase
        s.orchestratorTaskID = orchestratorTaskID
        s.orchestrationRole = orchestrationRole
        s.managerTaskID = managerTaskID
        return s
    }

    private static func testPartitionsByRunID() {
        let sessions = [
            session("a", slot: 1),
            session("b", slot: 2, run: "run-1", workflow: "feature-crew"),
            session("c", slot: 3, run: "run-2", workflow: "review-gate"),
            session("d", slot: 4, run: "run-1", workflow: "feature-crew"),
            session("e", slot: 5),
        ]
        let (runs, rest) = WorkflowRunGrouping.partition(sessions)
        precondition(runs.map(\.runID) == ["run-1", "run-2"], "group order follows first appearance")
        precondition(runs[0].members.map(\.id) == ["b", "d"], "members keep slot order")
        precondition(runs[1].members.map(\.id) == ["c"])
        precondition(rest.map(\.id) == ["a", "e"], "non-workflow sessions stay in the flat list")
    }

    private static func testUngroupedWhenNoWorkflowMeta() {
        let sessions = [session("a", slot: 1), session("b", slot: 2, run: "")]
        let (runs, rest) = WorkflowRunGrouping.partition(sessions)
        precondition(runs.isEmpty, "empty run id never forms a group")
        precondition(rest.map(\.id) == ["a", "b"])
    }

    private static func testAggregateIsWorstState() {
        let group = WorkflowRunGroup(runID: "r", workflowID: "w", members: [
            session("a", state: .done, run: "r"),
            session("b", state: .waiting, run: "r"),
            session("c", state: .running, run: "r"),
        ])
        precondition(group.aggregate == .waiting)
        precondition(group.needsAttention)
        let calm = WorkflowRunGroup(runID: "r", workflowID: "w", members: [
            session("a", state: .thinking, run: "r"),
            session("b", state: .idle, run: "r"),
        ])
        precondition(calm.aggregate == .thinking)
        precondition(!calm.needsAttention)
    }

    private static func testLeadPrefersOrchestrator() {
        let group = WorkflowRunGroup(runID: "r", workflowID: "w", members: [
            session("w1", slot: 2, run: "r", orchestrationRole: "worker", managerTaskID: "t-1"),
            session("orch", slot: 5, run: "r", orchestratorTaskID: "t-1", orchestrationRole: "orchestrator"),
        ])
        precondition(group.lead?.id == "orch", "double-tap selects the orchestrator, not the lowest slot")
        let noOrchestrator = WorkflowRunGroup(runID: "r", workflowID: "w", members: [
            session("w1", slot: 3, run: "r"),
            session("w2", slot: 7, run: "r"),
        ])
        precondition(noOrchestrator.lead?.id == "w1", "falls back to first member in slot order")
    }

    private static func testPhasesDistinctInFirstSeenOrder() {
        let group = WorkflowRunGroup(runID: "r", workflowID: "w", members: [
            session("a", run: "r", phase: "build"),
            session("b", run: "r", phase: "plan"),
            session("c", run: "r", phase: "build"),
            session("d", run: "r"),
        ])
        precondition(group.phases == ["build", "plan"])
    }

    private static func testDisplayNamePrettifies() {
        let group = WorkflowRunGroup(runID: "r", workflowID: "feature-crew_v2", members: [])
        precondition(group.displayName == "Feature Crew V2")
        precondition(group.aggregate == .idle, "empty group aggregates to idle")
    }

    private static func testSingletonRunStillGroups() {
        let (runs, rest) = WorkflowRunGrouping.partition([
            session("only", slot: 1, run: "run-1", workflow: "solo-act"),
        ])
        precondition(runs.count == 1 && runs[0].members.map(\.id) == ["only"],
                     "a one-member run still gets a header — that's where workflow membership shows")
        precondition(rest.isEmpty)
    }

    private static func testNextAttentionMember() {
        let group = WorkflowRunGroup(runID: "r", workflowID: "w", members: [
            session("calm", state: .running, run: "r"),
            session("wait1", state: .waiting, run: "r"),
            session("err", state: .error, run: "r"),
            session("wait2", state: .approval, run: "r"),
        ])
        precondition(group.nextAttentionMember(after: nil)?.id == "wait1",
                     "no focus → first attention member")
        precondition(group.nextAttentionMember(after: "calm")?.id == "wait1",
                     "focus outside the attention set → first attention member")
        precondition(group.nextAttentionMember(after: "wait1")?.id == "err",
                     "advances within the attention set")
        precondition(group.nextAttentionMember(after: "wait2")?.id == "wait1",
                     "wraps around")
        let calm = WorkflowRunGroup(runID: "r", workflowID: "w", members: [
            session("a", state: .running, run: "r"),
        ])
        precondition(calm.nextAttentionMember(after: nil) == nil,
                     "nil when nothing needs attention — the menu item disables")
    }
}
