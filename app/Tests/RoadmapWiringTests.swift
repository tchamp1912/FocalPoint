import Foundation

@main
enum RoadmapWiringTests {
    static func main() {
        let request = ManagedQuickLaunchRequest(
            task: "Wire the reviewed surface", cwd: "/private/tmp/project",
            agentType: "implementer", provider: .codex, model: "gpt-5.6-sol",
            title: "Wire UX", taskID: "wire-ux-001", complexity: .standard
        )
        let payload = request.daemonPayload
        precondition(payload["cmd"] as? String == "launch-session")
        precondition(payload["agent_type"] as? String == "implementer")
        precondition(payload["provider"] as? String == "codex")
        precondition(payload["model"] as? String == "gpt-5.6-sol")
        precondition(payload["task"] as? String == "Wire the reviewed surface")
        precondition(payload["cwd"] as? String == "/private/tmp/project")
        precondition(payload["title"] as? String == "Wire UX")
        precondition(payload["task_id"] as? String == "wire-ux-001")

        let unavailable = WorkflowRunActionAvailability.unavailable(reason: "Daemon capability is not reported.")
        let phaseAction = WorkflowRunPhaseAction(id: "approve", kind: .approveGate,
                                                 label: "Approve", detail: "Advance the gate.",
                                                 availability: unavailable)
        let command = WorkflowRunDashboardCommand.phaseAction(phaseID: "build", phaseName: "Build", action: phaseAction)
        precondition(WorkflowRunDashboardReducer.intent(for: command, availability: unavailable)
                     == .blocked(reason: "Daemon capability is not reported."))

        let focus = WorkflowRunDashboardCommand.focusRole(roleID: "session-1")
        precondition(WorkflowRunDashboardReducer.intent(for: focus, availability: .available) == .perform(focus))
        let stop = WorkflowRunDashboardCommand.stopRole(roleID: "session-1", roleTitle: "Worker")
        precondition(WorkflowRunDashboardReducer.intent(for: stop, availability: .available) == .confirm(stop))
        print("RoadmapWiringTests: PASS")
    }
}
