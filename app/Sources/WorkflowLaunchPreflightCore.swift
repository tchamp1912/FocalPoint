// FocalPoint menu-bar app — pure workflow launch-preflight models.
//
// This file deliberately imports Foundation only. Recommendation and
// validation behavior can be exercised without constructing SwiftUI views or
// connecting to focalpointd.
// MIT License.

import Foundation

enum WorkflowLaunchProvider: String, CaseIterable, Identifiable, Codable {
    case claude, codex, cursor, gemini

    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        }
    }
}

enum WorkflowComplexity: String, CaseIterable, Identifiable {
    case focused, substantial, complex

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var explanation: String {
        switch self {
        case .focused: return "A small, fixed crew with no dynamic expansion."
        case .substantial: return "Multiple roles or phases require sustained coordination."
        case .complex: return "Fan-out, several phases, or a large crew increases coordination risk."
        }
    }
}

struct WorkflowComplexitySignals: Equatable {
    let fixedRoleCount: Int
    let phaseCount: Int
    let fanoutCeiling: Int?
    let confirmationGateCount: Int
}

enum WorkflowLaunchRecommendations {
    static func complexity(for signals: WorkflowComplexitySignals) -> WorkflowComplexity {
        let score = signals.fixedRoleCount
            + signals.phaseCount * 2
            + (signals.fanoutCeiling ?? 0) * 2
            + signals.confirmationGateCount
        if signals.fanoutCeiling != nil || signals.phaseCount >= 3 || score >= 12 {
            return .complex
        }
        if signals.phaseCount > 0 || signals.fixedRoleCount >= 3 || score >= 5 {
            return .substantial
        }
        return .focused
    }

    static func fanoutLimit(ceiling: Int, complexity: WorkflowComplexity) -> Int {
        switch complexity {
        case .focused: return min(ceiling, 2)
        case .substantial: return min(ceiling, 3)
        case .complex: return min(ceiling, 4)
        }
    }
}

enum FormationGateSummary: String, Equatable {
    case authorized, confirm, auto

    var title: String { rawValue.capitalized }
    var explanation: String {
        switch self {
        case .authorized: return "Covered by the final formation confirmation."
        case .confirm: return "The orchestrator must stop and ask before this phase launches."
        case .auto: return "May continue without another prompt; only valid for fixed authority."
        }
    }
}

struct FormationRoleSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let kind: String
    let prep: String?
    let task: String?
    let phaseName: String?
    let fanoutMaximum: Int?
    /// For a fan-out placeholder (`fanoutMaximum != nil`), the name of the
    /// earlier role whose plan output names the slices. Structured so graph
    /// views never have to parse it back out of the placeholder's name.
    let fanoutSource: String?

    var displayName: String { fanoutMaximum == nil ? name : "\(name) (fan-out)" }
}

struct FormationPhaseSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let after: String?
    let gate: FormationGateSummary
    let roles: [FormationRoleSummary]
}

struct WorkflowRoleAssignment: Identifiable, Equatable {
    let id: String
    let roleName: String
    let typeName: String
    let phaseName: String?
    let gate: FormationGateSummary
    let fanoutMaximum: Int?
    var provider: WorkflowLaunchProvider
    var model: String
    let sourceDescription: String
}

struct WorkflowLaunchConfiguration: Equatable {
    let projectDirectory: URL
    let complexity: WorkflowComplexity
    let orchestratorProvider: WorkflowLaunchProvider
    let orchestratorModel: String
    let fanoutLimit: Int?
    let roleAssignments: [WorkflowRoleAssignment]

    var daemonAssignmentManifest: [[String: Any]] {
        roleAssignments.map { assignment in
            let limit = assignment.fanoutMaximum.map {
                min($0, fanoutLimit ?? $0)
            } ?? 1
            return [
                "assignment_id": assignment.id,
                "phase": assignment.phaseName ?? "main",
                "agent_type": assignment.typeName,
                "provider": assignment.provider.rawValue,
                "model": assignment.model,
                "gate": assignment.gate.rawValue,
                "fanout": assignment.fanoutMaximum != nil,
                "fanout_limit": limit,
            ]
        }
    }
}

enum WorkflowPreflightValidation {
    static func errors(projectDirectory: URL?, orchestratorModel: String,
                       assignments: [WorkflowRoleAssignment], fanoutLimit: Int?,
                       fanoutCeiling: Int?, unresolvedTypes: [String]) -> [String] {
        var errors: [String] = []
        if projectDirectory == nil {
            errors.append("Choose the project folder this workflow may operate in.")
        } else if let projectDirectory {
            var isDirectory: ObjCBool = false
            if !FileManager.default.fileExists(atPath: projectDirectory.path,
                                               isDirectory: &isDirectory) || !isDirectory.boolValue {
                errors.append("The selected project folder no longer exists.")
            }
        }
        if orchestratorModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Choose an explicit orchestrator model.")
        }
        for assignment in assignments where
            assignment.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Choose an explicit model for \(assignment.roleName).")
        }
        for type in Array(Set(unresolvedTypes)).sorted() {
            errors.append("Agent type '\(type)' is missing or invalid, so its provider cannot be resolved.")
        }
        if let ceiling = fanoutCeiling {
            guard let limit = fanoutLimit, (1...ceiling).contains(limit) else {
                errors.append("Fan-out limit must be between 1 and \(ceiling).")
                return errors
            }
        }
        return errors
    }
}
