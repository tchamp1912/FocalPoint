// FocalPoint — adapter-facing models for the live workflow run dashboard.
//
// These types intentionally do not depend on AppModel or daemon DTOs. A daemon
// integration can map whatever protocol revision it understands into a
// WorkflowRunDashboardSnapshot and expose only the actions that revision
// actually supports.
// MIT License.

import Foundation

enum WorkflowRunState: String, CaseIterable, Codable, Hashable {
    case queued, running, waiting, blocked, stopping, completed, failed, cancelled

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .blocked: return "Blocked"
        case .stopping: return "Stopping"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }
}

enum WorkflowRunPhaseState: String, CaseIterable, Codable, Hashable {
    case pending, ready, running, awaitingGate, completed, failed, skipped

    var title: String {
        switch self {
        case .pending: return "Pending"
        case .ready: return "Ready"
        case .running: return "Running"
        case .awaitingGate: return "Awaiting gate"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }
}

enum WorkflowRunRoleState: String, CaseIterable, Codable, Hashable {
    case queued, starting, working, waiting, approval, completed, failed, stopped, disconnected

    var title: String {
        switch self {
        case .queued: return "Queued"
        case .starting: return "Starting"
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .approval: return "Approval needed"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .disconnected: return "Disconnected"
        }
    }

    var needsAttention: Bool { self == .waiting || self == .approval || self == .failed || self == .disconnected }
}

enum WorkflowRunSessionHealth: String, CaseIterable, Codable, Hashable {
    case healthy, delayed, stale, disconnected, unknown

    var title: String { rawValue.capitalized }
}

enum WorkflowRunGateKind: String, CaseIterable, Codable, Hashable {
    case authorized, confirm, automatic

    var title: String {
        switch self {
        case .authorized: return "Pre-authorized"
        case .confirm: return "Human confirmation"
        case .automatic: return "Automatic"
        }
    }
}

/// Whether a specific adapter action can be offered right now. Keeping the
/// reason beside the capability prevents UI call sites from inventing generic
/// explanations or accidentally enabling commands against older daemons.
enum WorkflowRunActionAvailability: Equatable, Hashable {
    case available
    case unavailable(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

struct WorkflowRunContext: Equatable, Hashable {
    var usedTokens: Int
    var limitTokens: Int

    var fraction: Double {
        guard limitTokens > 0 else { return 0 }
        return min(max(Double(usedTokens) / Double(limitTokens), 0), 1)
    }
}

struct WorkflowRunPhaseAction: Identifiable, Equatable, Hashable {
    enum Kind: String, Equatable, Hashable {
        case approveGate, rejectGate, startPhase, retryPhase, skipPhase
    }

    enum Emphasis: String, Equatable, Hashable {
        case standard, preferred, destructive
    }

    var id: String
    var kind: Kind
    var label: String
    var detail: String
    var emphasis: Emphasis = .standard
    var availability: WorkflowRunActionAvailability
}

struct WorkflowRunPhase: Identifiable, Equatable, Hashable {
    var id: String
    var sequence: Int
    var name: String
    var purpose: String?
    var state: WorkflowRunPhaseState
    var gate: WorkflowRunGateKind
    var startedAt: Date?
    var updatedAt: Date?
    var finishedAt: Date?
    var actions: [WorkflowRunPhaseAction] = []
}

struct WorkflowRunRole: Identifiable, Equatable, Hashable {
    var id: String
    var phaseID: String
    var name: String
    var title: String
    var sessionID: String?
    var state: WorkflowRunRoleState
    var health: WorkflowRunSessionHealth
    var healthDetail: String?
    var provider: String?
    var model: String?
    var costUSD: Double?
    var context: WorkflowRunContext?
    var startedAt: Date?
    var updatedAt: Date?
    var finishedAt: Date?
    var focusAvailability: WorkflowRunActionAvailability
    var stopAvailability: WorkflowRunActionAvailability
}

struct WorkflowRunDashboardSnapshot: Identifiable, Equatable {
    var id: String
    var title: String
    var formationName: String
    var state: WorkflowRunState
    var statusDetail: String?
    var phases: [WorkflowRunPhase]
    var roles: [WorkflowRunRole]
    var startedAt: Date?
    var updatedAt: Date
    var finishedAt: Date?
    var budgetUSD: Double?
    var costUSD: Double?

    var activePhaseID: String? {
        phases.first(where: { $0.state == .running || $0.state == .awaitingGate || $0.state == .ready })?.id
    }

    var attentionCount: Int { roles.lazy.filter(\.state.needsAttention).count }

    var knownContextFraction: Double? {
        let values = roles.compactMap(\.context?.fraction)
        return values.max()
    }

    var healthyRoleCount: Int { roles.lazy.filter { $0.health == .healthy }.count }
}

/// The only integration surface with side effects. Adapters can capture a
/// daemon client, test spy, or preview recorder without the dashboard knowing
/// which transport is in use.
struct WorkflowRunDashboardActions {
    var focusRole: (_ roleID: String) -> Void
    var stopRole: (_ roleID: String) -> Void
    var performPhaseAction: (_ phaseID: String, _ actionID: String) -> Void

    static let disabled = WorkflowRunDashboardActions(
        focusRole: { _ in }, stopRole: { _ in }, performPhaseAction: { _, _ in }
    )
}

enum WorkflowRunDashboardCommand: Equatable {
    case focusRole(roleID: String)
    case stopRole(roleID: String, roleTitle: String)
    case phaseAction(phaseID: String, phaseName: String, action: WorkflowRunPhaseAction)
}

enum WorkflowRunDashboardIntent: Equatable {
    case perform(WorkflowRunDashboardCommand)
    case confirm(WorkflowRunDashboardCommand)
    case blocked(reason: String)
}

struct WorkflowRunConfirmation: Equatable {
    var title: String
    var message: String
    var confirmLabel: String
    var isDestructive: Bool
}

/// Pure action policy used by the view and unit-testable without SwiftUI.
/// Focus is reversible and immediate; stopping and every gate/phase transition
/// require confirmation, even if an adapter accidentally labels one benign.
enum WorkflowRunDashboardReducer {
    static func intent(for command: WorkflowRunDashboardCommand,
                       availability: WorkflowRunActionAvailability) -> WorkflowRunDashboardIntent {
        guard availability.isAvailable else {
            return .blocked(reason: availability.reason ?? "This action is not available.")
        }
        switch command {
        case .focusRole:
            return .perform(command)
        case .stopRole, .phaseAction:
            return .confirm(command)
        }
    }

    static func confirmation(for command: WorkflowRunDashboardCommand) -> WorkflowRunConfirmation? {
        switch command {
        case .focusRole:
            return nil
        case .stopRole(_, let roleTitle):
            return WorkflowRunConfirmation(
                title: "Stop \(roleTitle)?",
                message: "This asks the workflow adapter to stop the live session. Work in progress may be lost.",
                confirmLabel: "Stop role",
                isDestructive: true
            )
        case .phaseAction(_, let phaseName, let action):
            return WorkflowRunConfirmation(
                title: "\(action.label) — \(phaseName)?",
                message: action.detail + " This changes workflow execution and cannot be undone from this dashboard.",
                confirmLabel: action.label,
                isDestructive: action.emphasis == .destructive
            )
        }
    }
}
