// FocalPoint menu-bar app — previews, samples, and executable behavior checks.
// MIT License.

import Foundation

enum SessionTriageFixtures {
    static let sessions: [SessionTriageSession] = {
        let now = Date()
        return [
            .init(id: "orch-design", title: "Design lead", slot: 1, provider: "Claude", project: "FocalPoint", workflow: "UX roadmap", state: .thinking, isManaged: true, updatedAt: now.addingTimeInterval(-40), stableTaskID: "ux-lead", isManager: true),
            .init(id: "triage", title: "Session triage", slot: 7, provider: "Codex", project: "FocalPoint", workflow: "UX roadmap", state: .running, isManaged: true, updatedAt: now.addingTimeInterval(-8), stableTaskID: "ux-triage", managerTaskID: "ux-lead"),
            .init(id: "alerts", title: "Approval flow", slot: 4, provider: "Claude", project: "FocalPoint", workflow: "UX roadmap", state: .approval, isManaged: true, updatedAt: now.addingTimeInterval(-120), stableTaskID: "ux-alerts", managerTaskID: "ux-lead"),
            .init(id: "docs", title: "Release notes", slot: 10, provider: "Cursor", project: "Website", workflow: "Release", state: .waiting, isManaged: false, updatedAt: now.addingTimeInterval(-360)),
            .init(id: "tests", title: "Integration tests", slot: 3, provider: "Codex", project: "Daemon", workflow: "Nightly", state: .error, isManaged: true, isConnected: false, updatedAt: now.addingTimeInterval(-600)),
            .init(id: "idle", title: "Scratchpad", provider: "Claude", project: "No project", state: .idle, isManaged: false, updatedAt: now.addingTimeInterval(-2400))
        ]
    }()

    /// Lightweight assertions suitable for a future unit-test target and useful
    /// in previews/debug harnesses today. Returns messages instead of trapping.
    static func validateEngine() -> [String] {
        var failures: [String] = []
        var filters = SessionTriageFilters()
        filters.providers = ["Codex"]
        filters.states = [.error]
        let filtered = SessionTriageEngine.filter(sessions, search: "daemon", filters: filters)
        if filtered.map(\.id) != ["tests"] { failures.append("combined filters/search") }

        let sorted = SessionTriageEngine.sort(sessions, by: .slot)
        if sorted.compactMap(\.slot) != [1, 3, 4, 7, 10] { failures.append("slot sorting") }
        if Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.slot) }) !=
            Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.slot) }) {
            failures.append("stable slot identity")
        }

        let groups = SessionTriageEngine.group(sessions, by: .manager)
        let lead = groups.first { $0.id == "manager:ux-lead" }
        if Set(lead?.sessions.map(\.id) ?? []) != ["orch-design", "triage", "alerts"] {
            failures.append("manager grouping")
        }
        return failures
    }
}
