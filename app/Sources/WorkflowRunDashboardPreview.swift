// FocalPoint — deterministic dashboard preview fixtures.
// MIT License.

import SwiftUI

enum WorkflowRunDashboardSamples {
    /// Fixed timestamps keep screenshots and reducer/UI tests deterministic.
    static let referenceDate = Date(timeIntervalSince1970: 1_788_890_400) // 2026-09-08T18:00:00Z

    static let live = WorkflowRunDashboardSnapshot(
        id: "run-ux-042",
        title: "FocalPoint UX roadmap",
        formationName: "bounded-delivery",
        state: .waiting,
        statusDetail: "Implementation is waiting for a human release gate.",
        phases: [
            WorkflowRunPhase(
                id: "discovery", sequence: 1, name: "Discovery", purpose: "Audit current workflow surfaces and establish constraints.",
                state: .completed, gate: .authorized,
                startedAt: referenceDate.addingTimeInterval(-7_200),
                updatedAt: referenceDate.addingTimeInterval(-5_500),
                finishedAt: referenceDate.addingTimeInterval(-5_500)
            ),
            WorkflowRunPhase(
                id: "implementation", sequence: 2, name: "Implementation", purpose: "Build the approved product areas in parallel and verify each slice.",
                state: .awaitingGate, gate: .confirm,
                startedAt: referenceDate.addingTimeInterval(-5_400),
                updatedAt: referenceDate.addingTimeInterval(-75), finishedAt: nil,
                actions: [
                    WorkflowRunPhaseAction(
                        id: "approve-release", kind: .approveGate, label: "Approve release phase",
                        detail: "Start the release phase using the implementation handoff.", emphasis: .preferred,
                        availability: .available
                    ),
                    WorkflowRunPhaseAction(
                        id: "reject-release", kind: .rejectGate, label: "Reject transition",
                        detail: "Keep this phase active and return the handoff for revision.", emphasis: .destructive,
                        availability: .available
                    )
                ]
            ),
            WorkflowRunPhase(
                id: "release", sequence: 3, name: "Release", purpose: "Integrate verified changes and prepare the handoff.",
                state: .pending, gate: .automatic, startedAt: nil, updatedAt: nil, finishedAt: nil,
                actions: [
                    WorkflowRunPhaseAction(
                        id: "start-release", kind: .startPhase, label: "Start now",
                        detail: "Start this phase before its declared gate is satisfied.", emphasis: .standard,
                        availability: .unavailable(reason: "The implementation confirmation gate has not been approved.")
                    )
                ]
            )
        ],
        roles: [
            WorkflowRunRole(
                id: "dashboard", phaseID: "implementation", name: "dashboard", title: "Live run dashboard",
                sessionID: "01a02bdf", state: .working, health: .healthy,
                healthDetail: "Heartbeat 12s ago", provider: "Codex", model: "gpt-5.6-codex",
                costUSD: 1.84, context: WorkflowRunContext(usedTokens: 86_200, limitTokens: 128_000),
                startedAt: referenceDate.addingTimeInterval(-3_400), updatedAt: referenceDate.addingTimeInterval(-12), finishedAt: nil,
                focusAvailability: .available, stopAvailability: .available
            ),
            WorkflowRunRole(
                id: "navigation", phaseID: "implementation", name: "navigation", title: "Workflow navigation",
                sessionID: "01a02c01", state: .approval, health: .delayed,
                healthDetail: "Awaiting approval for 4m", provider: "Claude", model: "claude-opus-4-6",
                costUSD: 2.37, context: WorkflowRunContext(usedTokens: 118_000, limitTokens: 128_000),
                startedAt: referenceDate.addingTimeInterval(-3_300), updatedAt: referenceDate.addingTimeInterval(-240), finishedAt: nil,
                focusAvailability: .available, stopAvailability: .available
            ),
            WorkflowRunRole(
                id: "observer", phaseID: "implementation", name: "observer", title: "External observer",
                sessionID: nil, state: .disconnected, health: .unknown,
                healthDetail: "Adapter does not report session health", provider: nil, model: nil,
                costUSD: nil, context: nil, startedAt: nil, updatedAt: nil, finishedAt: nil,
                focusAvailability: .unavailable(reason: "This role has no focusable session."),
                stopAvailability: .unavailable(reason: "Stopping roles is not supported by this adapter.")
            )
        ],
        startedAt: referenceDate.addingTimeInterval(-7_200),
        updatedAt: referenceDate,
        finishedAt: nil,
        budgetUSD: 8,
        costUSD: 4.21
    )
}

struct WorkflowRunDashboard_Previews: PreviewProvider {
    static var previews: some View {
        WorkflowRunDashboardView(snapshot: WorkflowRunDashboardSamples.live)
            .frame(width: 1040, height: 700)
            .previewDisplayName("Live workflow run")
    }
}
