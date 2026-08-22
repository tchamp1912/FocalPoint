// FocalPoint menu-bar app — typed models and pure transformations for session triage.
// MIT License.

import Foundation

/// A presentation-ready session record for the triage surface. It deliberately
/// carries stable session, slot, and orchestration identities separately: sorting
/// and grouping may move a row on screen, but never rewrite its keyboard slot.
struct SessionTriageSession: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var slot: Int?
    var provider: String
    var project: String
    var workflow: String
    var state: AgentState
    var isManaged: Bool
    var isConnected: Bool
    var updatedAt: Date
    var stableTaskID: String?
    var managerTaskID: String?
    var isManager: Bool

    var needsAttention: Bool { state.needsAttention || !isConnected }

    init(
        id: String,
        title: String,
        slot: Int? = nil,
        provider: String,
        project: String = "No project",
        workflow: String = "Independent",
        state: AgentState,
        isManaged: Bool,
        isConnected: Bool = true,
        updatedAt: Date = .now,
        stableTaskID: String? = nil,
        managerTaskID: String? = nil,
        isManager: Bool = false
    ) {
        self.id = id
        self.title = title
        self.slot = slot
        self.provider = provider
        self.project = project
        self.workflow = workflow
        self.state = state
        self.isManaged = isManaged
        self.isConnected = isConnected
        self.updatedAt = updatedAt
        self.stableTaskID = stableTaskID
        self.managerTaskID = managerTaskID
        self.isManager = isManager
    }

    /// Bridges the live app model without requiring changes to Protocol.swift.
    /// A future caller with richer workflow metadata can use the designated init.
    init(session: SessionInfo, workflow: String = "Independent") {
        let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "No project"
        self.init(
            id: session.id,
            title: session.title,
            slot: session.slot,
            provider: session.kind,
            project: project,
            workflow: workflow,
            state: session.state,
            isManaged: session.isManaged,
            isConnected: session.connected,
            updatedAt: session.lastChange,
            stableTaskID: session.orchestratorTaskID,
            managerTaskID: session.managerTaskID,
            isManager: session.isOrchestrator
        )
    }
}

enum SessionTriageManagedStatus: String, CaseIterable, Identifiable, Sendable {
    case managed
    case unmanaged

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum SessionTriageSort: String, CaseIterable, Identifiable, Sendable {
    case attention
    case slot
    case recentlyUpdated
    case title

    var id: String { rawValue }
    var title: String {
        switch self {
        case .attention: return "Needs attention"
        case .slot: return "Slot"
        case .recentlyUpdated: return "Recently updated"
        case .title: return "Name"
        }
    }
}

enum SessionTriageGrouping: String, CaseIterable, Identifiable, Sendable {
    case manager
    case workflow
    case project
    case none

    var id: String { rawValue }
    var title: String {
        switch self {
        case .manager: return "Manager"
        case .workflow: return "Workflow"
        case .project: return "Project"
        case .none: return "No grouping"
        }
    }
}

struct SessionTriageFilters: Equatable, Sendable {
    var projects: Set<String> = []
    var providers: Set<String> = []
    var workflows: Set<String> = []
    var states: Set<AgentState> = []
    var managedStatuses: Set<SessionTriageManagedStatus> = []
    var attentionOnly = false

    var activeDimensionCount: Int {
        [!projects.isEmpty, !providers.isEmpty, !workflows.isEmpty,
         !states.isEmpty, !managedStatuses.isEmpty, attentionOnly]
            .filter { $0 }.count
    }

    mutating func clear() { self = SessionTriageFilters() }
}

struct SessionTriageGroup: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sessions: [SessionTriageSession]
    var attentionCount: Int { sessions.filter(\.needsAttention).count }
}

struct SessionTriageFilterOptions: Equatable, Sendable {
    let projects: [String]
    let providers: [String]
    let workflows: [String]
    let states: [AgentState]
}

/// Namespace for deterministic, UI-independent behavior that can be unit tested
/// without hosting SwiftUI or waiting for the search debounce.
enum SessionTriageEngine {
    static func options(for sessions: [SessionTriageSession]) -> SessionTriageFilterOptions {
        SessionTriageFilterOptions(
            projects: uniqueSorted(sessions.map(\.project)),
            providers: uniqueSorted(sessions.map(\.provider)),
            workflows: uniqueSorted(sessions.map(\.workflow)),
            states: AgentState.allCases.filter { state in sessions.contains { $0.state == state } }
        )
    }

    static func filter(
        _ sessions: [SessionTriageSession],
        search: String,
        filters: SessionTriageFilters
    ) -> [SessionTriageSession] {
        let terms = search
            .split(whereSeparator: \.isWhitespace)
            .map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }

        return sessions.filter { session in
            if filters.attentionOnly && !session.needsAttention { return false }
            if !filters.projects.isEmpty && !filters.projects.contains(session.project) { return false }
            if !filters.providers.isEmpty && !filters.providers.contains(session.provider) { return false }
            if !filters.workflows.isEmpty && !filters.workflows.contains(session.workflow) { return false }
            if !filters.states.isEmpty && !filters.states.contains(session.state) { return false }
            let status: SessionTriageManagedStatus = session.isManaged ? .managed : .unmanaged
            if !filters.managedStatuses.isEmpty && !filters.managedStatuses.contains(status) { return false }
            guard !terms.isEmpty else { return true }
            let haystack = [session.title, session.provider, session.project, session.workflow,
                            session.state.display, session.stableTaskID ?? ""]
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return terms.allSatisfy(haystack.contains)
        }
    }

    static func sort(
        _ sessions: [SessionTriageSession],
        by order: SessionTriageSort
    ) -> [SessionTriageSession] {
        sessions.sorted { lhs, rhs in
            switch order {
            case .attention:
                let l = (lhs.needsAttention ? 1 : 0, lhs.state.severity)
                let r = (rhs.needsAttention ? 1 : 0, rhs.state.severity)
                if l != r { return l > r }
            case .slot:
                let l = lhs.slot ?? Int.max
                let r = rhs.slot ?? Int.max
                if l != r { return l < r }
            case .recentlyUpdated:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            case .title:
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            // Stable, deterministic tie-breakers; slot remains data, never an index.
            if lhs.slot != rhs.slot { return (lhs.slot ?? Int.max) < (rhs.slot ?? Int.max) }
            return lhs.id < rhs.id
        }
    }

    static func group(
        _ sessions: [SessionTriageSession],
        by grouping: SessionTriageGrouping,
        managerDirectory: [SessionTriageSession]? = nil
    ) -> [SessionTriageGroup] {
        if grouping == .none {
            return sessions.isEmpty ? [] : [SessionTriageGroup(id: "all", title: "All sessions", sessions: sessions)]
        }

        // Use the full unfiltered directory when available so a manager's
        // human title survives even when only one of its workers matches.
        let managersByTask = (managerDirectory ?? sessions).reduce(into: [String: String]()) { result, row in
            guard row.isManager, let task = row.stableTaskID else { return }
            result[task] = row.title
        }
        let pairs: [(String, String, SessionTriageSession)] = sessions.map { row in
            switch grouping {
            case .manager:
                if row.isManager { return ("manager:\(row.stableTaskID ?? row.id)", row.title, row) }
                if let manager = row.managerTaskID {
                    return ("manager:\(manager)", managersByTask[manager] ?? "Manager \(manager)", row)
                }
                return ("manager:independent", "Independent", row)
            case .workflow: return ("workflow:\(row.workflow)", row.workflow, row)
            case .project: return ("project:\(row.project)", row.project, row)
            case .none: return ("all", "All sessions", row)
            }
        }

        let buckets = Dictionary(grouping: pairs, by: { $0.0 })
        return buckets.map { id, rows in
            let groupedSessions = rows.map(\.2)
            let ordered = grouping == .manager
                ? groupedSessions.filter(\.isManager) + groupedSessions.filter { !$0.isManager }
                : groupedSessions
            return SessionTriageGroup(id: id, title: rows[0].1, sessions: ordered)
        }.sorted {
            if $0.id == "manager:independent" { return false }
            if $1.id == "manager:independent" { return true }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
