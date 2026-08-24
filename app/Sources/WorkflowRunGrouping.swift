// FocalPoint menu-bar app — workflow-run grouping of live sessions.
//
// Pure presentation logic (Foundation-only, no SwiftUI): partitions the
// active session list into per-run groups so the menu dropdown and desktop
// widget can draw a workflow's agents under the workflow instead of mixed
// into the flat list. Keyed on `workflow_run_id` from session meta
// (PROTOCOL.md §4) — live per-session data, so the groups track the session
// stream with no extra fetch. Slots are untouched: a member's numbered badge
// still reads whatever the daemon assigned it.
// MIT License.

import Foundation

/// One live workflow run's sessions, in daemon slot order.
struct WorkflowRunGroup: Identifiable, Equatable {
    var id: String { runID }
    let runID: String
    /// The formation id (`workflow_id` meta) — e.g. "feature-crew".
    let workflowID: String
    var members: [SessionInfo]

    /// Worst state across members — same severity ordering as the daemon's
    /// own aggregate, so a run with one `waiting` worker reads Waiting.
    var aggregate: AgentState {
        members.map(\.state).max(by: { $0.severity < $1.severity }) ?? .idle
    }

    var needsAttention: Bool { members.contains { $0.state.needsAttention } }

    /// The session double-tapping a member's number should select: the run's
    /// orchestrator when one is identifiable (accept/reject/PTT then route to
    /// the workflow's lead), else the first member in slot order.
    var lead: SessionInfo? {
        members.first(where: \.isOrchestrator) ?? members.first
    }

    /// Distinct phase names among members, first-seen order — the header's
    /// compact "plan · build · review" summary.
    var phases: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for member in members {
            guard let phase = member.workflowPhase, !phase.isEmpty, !seen.contains(phase) else { continue }
            seen.insert(phase)
            ordered.append(phase)
        }
        return ordered
    }

    /// "feature-crew" → "Feature Crew". Presentation-only; the id stays the
    /// identity.
    var displayName: String {
        let words = workflowID
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? workflowID : words.joined(separator: " ")
    }

    /// Next member needing attention after `currentSessionID`, wrapping
    /// around; the first attention member when the currently focused session
    /// isn't in the run's attention set (or nothing is focused). Nil when no
    /// member needs attention — callers disable the action in that case.
    func nextAttentionMember(after currentSessionID: String?) -> SessionInfo? {
        let attention = members.filter { $0.state.needsAttention }
        guard !attention.isEmpty else { return nil }
        if let currentSessionID,
           let index = attention.firstIndex(where: { $0.id == currentSessionID }) {
            return attention[(index + 1) % attention.count]
        }
        return attention[0]
    }
}

enum WorkflowRunGrouping {
    /// Partition `sessions` (already in daemon slot order) into workflow-run
    /// groups plus the ungrouped remainder. A session joins a run iff its
    /// `workflow_run_id` meta is present and non-empty; everything else keeps
    /// its place in `rest`. Group order follows first appearance, which —
    /// given slot-ordered input — is lowest-slot-first.
    ///
    /// A run id with exactly one live member still forms a group: the header
    /// is where "this agent belongs to a workflow" is communicated, and the
    /// group collapses away only when the run's last session ends.
    static func partition(_ sessions: [SessionInfo]) -> (runs: [WorkflowRunGroup], rest: [SessionInfo]) {
        var order: [String] = []
        var byRun: [String: [SessionInfo]] = [:]
        var rest: [SessionInfo] = []
        for session in sessions {
            guard let runID = session.workflowRunID, !runID.isEmpty else {
                rest.append(session)
                continue
            }
            if byRun[runID] == nil { order.append(runID) }
            byRun[runID, default: []].append(session)
        }
        let runs = order.map { runID in
            let members = byRun[runID] ?? []
            let workflowID = members.lazy
                .compactMap(\.workflowID)
                .first(where: { !$0.isEmpty }) ?? runID
            return WorkflowRunGroup(runID: runID, workflowID: workflowID, members: members)
        }
        return (runs, rest)
    }
}
