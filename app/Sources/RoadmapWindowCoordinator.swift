// FocalPoint — production wiring for the roadmap UX surfaces.
//
// This is intentionally the one place that turns AppModel's live transport
// records into the richer window presentations. Views retain no sample data
// and every side effect routes back through an AppModel command.

import AppKit
import Combine
import SwiftUI

@MainActor
final class RoadmapWindowCoordinator {
    private let model: AppModel
    private var windows: [String: NSWindowController] = [:]

    init(model: AppModel) { self.model = model }

    func showQuickLaunch() {
        show("quick-launch", title: "Launch Managed Agent", size: NSSize(width: 680, height: 740)) { [weak self] in
            guard let self else { return AnyView(EmptyView()) }
            return AnyView(LiveQuickLaunchView(model: self.model, onCancel: { [weak self] in self?.close("quick-launch") }))
        }
    }

    // Session Triage, History, and the workflow-runs dashboard live in the
    // unified main window (MainWindowController); the Live* views below are
    // shared with it. Quick Launch and Diagnostics stay standalone windows:
    // both are modal-ish task flows, not browsing surfaces.

    func showDiagnostics() {
        show("diagnostics", title: "FocalPoint Setup Diagnostics", size: NSSize(width: 720, height: 700)) { [weak self] in
            AnyView(LiveSetupDiagnosticsView(model: self?.model ?? .shared))
        }
    }

    private func show(_ key: String, title: String, size: NSSize, root: () -> AnyView) {
        if let window = windows[key]?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root()))
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        windows[key] = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.center()
    }

    private func close(_ key: String) {
        windows[key]?.close()
        windows[key] = nil
    }
}

// MARK: - Live wrappers

private struct LiveQuickLaunchView: View {
    @ObservedObject var model: AppModel
    let onCancel: () -> Void

    var body: some View {
        ManagedQuickLaunchView(initialCwd: RoadmapPresentation.preferredCwd(from: model.sessions),
                               actions: .init(launch: { model.launchManagedQuickSession($0) }, cancel: onCancel),
                               launchFailureMessage: model.roadmapActionError)
            .onAppear { model.clearRoadmapActionError() }
    }
}

/// Live session triage over AppModel. Shared by the unified main window's
/// Triage detail.
struct LiveSessionTriageView: View {
    @ObservedObject var model: AppModel
    @StateObject private var triage: SessionTriageViewModel

    init(model: AppModel) {
        self.model = model
        _triage = StateObject(wrappedValue: SessionTriageViewModel(
            sessions: model.sessions,
            workflow: { $0.workflowID ?? "Independent" },
            onFocus: { triageSession in
                guard let session = model.sessions.first(where: { $0.id == triageSession.id }) else { return }
                model.focusSession(session)
            },
            onStop: { triageSession in
                model.stopSessionAfterUserConfirmation(id: triageSession.id)
            }
        ))
    }

    var body: some View {
        SessionTriageView(model: triage)
            .onAppear { synchronize() }
            .onReceive(model.$sessions) { _ in synchronize() }
    }

    private func synchronize() {
        triage.replaceLiveSessions(model.sessions)
    }
}

/// Live workflow-runs dashboard over AppModel. Shared by the roadmap window
/// and the unified main window's Runs detail.
struct LiveWorkflowDashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let snapshot = RoadmapPresentation.dashboard(from: model) {
                WorkflowRunDashboardView(snapshot: snapshot,
                    actions: .init(
                        focusRole: { roleID in
                            guard let id = RoadmapPresentation.sessionID(forRoleID: roleID, model: model),
                                  let session = model.sessions.first(where: { $0.id == id }) else { return }
                            model.focusSession(session)
                        },
                        stopRole: { roleID in
                            guard let id = RoadmapPresentation.sessionID(forRoleID: roleID, model: model) else { return }
                            model.stopSessionAfterUserConfirmation(id: id)
                        },
                        performPhaseAction: { _, _ in
                            assertionFailure("Phase actions are not bound unless the daemon reports a capability.")
                        }
                    ))
            } else {
                ContentUnavailableView("No workflow runs", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text("Live workflow runs will appear when the daemon reports them."))
                    .frame(minWidth: 820, minHeight: 570)
                    .onAppear { model.refreshRoadmapState() }
            }
        }
    }
}

private struct LiveSetupDiagnosticsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            if let diagnostics = model.daemonDiagnostics {
                HStack(spacing: 10) {
                    Image(systemName: model.connected ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(model.connected ? .green : .red)
                    Text("Daemon: \(diagnostics.liveSessions) live · \(diagnostics.openChannels) channels · \(diagnostics.sessionsNeedingDiagnostics) need diagnostics")
                        .font(.caption)
                    Spacer()
                    Button("Refresh") { model.refreshRoadmapState() }.controlSize(.small)
                }
                .padding(.horizontal, 20).padding(.vertical, 9)
                Divider()
            }
            SetupDiagnosticsView(mode: .diagnostics)
                .onAppear { model.refreshRoadmapState() }
        }
    }
}

/// Live history workspace over AppModel. Shared by the unified main
/// window's History detail.
struct LiveHistoryWorkspaceView: View {
    @ObservedObject var model: AppModel
    @StateObject private var store: HistoryWorkspaceStore

    init(model: AppModel) {
        self.model = model
        _store = StateObject(wrappedValue: HistoryWorkspaceStore(
            records: RoadmapPresentation.history(from: model),
            launchOptions: [],
            actionHandler: { action in RoadmapPresentation.apply(action, to: model) }
        ))
    }

    var body: some View {
        HistoryWorkspaceView(store: store)
            .onReceive(model.$sessionHistory) { _ in store.replaceRecords(RoadmapPresentation.history(from: model)) }
            .onReceive(model.$pinnedHistoryIDs) { _ in store.replaceRecords(RoadmapPresentation.history(from: model)) }
    }
}

// MARK: - Deterministic mappings

@MainActor
enum RoadmapPresentation {
    static func preferredCwd(from sessions: [SessionInfo]) -> String {
        sessions.first(where: { $0.connected && !($0.cwd ?? "").isEmpty })?.cwd ?? ""
    }

    static func history(from model: AppModel) -> [HistoryRecord] {
        model.sessionHistory.map { entry in
            let provider = HistoryProvider(rawValue: entry.kind.lowercased()) ?? .codex
            let path = entry.cwd ?? ""
            return HistoryRecord(
                id: entry.id, title: entry.title, summary: entry.finalState.display,
                provider: provider, model: "Not retained", state: historyState(entry.finalState),
                project: .init(id: path.isEmpty ? "unknown" : path,
                               name: path.isEmpty ? "Original project unavailable" : URL(fileURLWithPath: path).lastPathComponent,
                               path: path), workflow: nil,
                startedAt: entry.startedAt, endedAt: entry.endedAt,
                usage: .init(tokensIn: Int(entry.stats[.tokensIn] ?? 0), tokensOut: Int(entry.stats[.tokensOut] ?? 0),
                             toolCalls: Int(entry.stats[.toolCalls] ?? 0), estimatedCostUSD: entry.stats[.cost]),
                sourcePrompt: nil, resumeToken: ["claude", "codex"].contains(entry.kind.lowercased()) ? entry.sessionID : nil,
                isPinned: model.pinnedHistoryIDs.contains(entry.id)
            )
        }
    }

    static func apply(_ action: HistoryWorkspaceAction, to model: AppModel) {
        switch action {
        case .pin(let id, let isPinned):
            if let entry = model.sessionHistory.first(where: { $0.id == id }) { model.setHistoryPinned(entry, pinned: isPinned) }
        case .delete(let ids):
            model.sessionHistory.filter { ids.contains($0.id) }.forEach { model.deleteHistoryEntry($0) }
        case .launch(let request):
            // The workspace only offers Resume when AppModel's eligibility
            // allows it; it deliberately has no synthetic rerun prompt.
            if request.mode == .resume,
               let entry = model.sessionHistory.first(where: { $0.id == request.sourceRecordID }) {
                model.recoverSession(entry)
            }
        }
    }

    static func dashboard(from model: AppModel) -> WorkflowRunDashboardSnapshot? {
        guard let run = model.workflowRuns.first else { return nil }
        let runSessions = run.sessions
        let phases = Dictionary(grouping: runSessions, by: { $0.phase ?? "Unassigned" })
            .sorted { $0.key < $1.key }
            .enumerated().map { index, group in
                WorkflowRunPhase(id: group.key, sequence: index + 1, name: group.key, purpose: nil,
                                 state: group.value.contains(where: { $0.state.needsAttention }) ? .awaitingGate : .running,
                                 gate: group.value.compactMap(\.gate).contains(.confirm) ? .confirm : .automatic,
                                 startedAt: nil, updatedAt: Date(), finishedAt: nil,
                                 actions: []) // No command is shown without a daemon capability + bound action.
            }
        let roles = runSessions.map { item -> WorkflowRunRole in
            let session = model.sessions.first(where: { $0.id == item.sessionID })
            let canFocus = session.map { _ in WorkflowRunActionAvailability.available } ?? .unavailable(reason: "The live session is no longer available.")
            let canStop: WorkflowRunActionAvailability = (session?.isManaged == true && !(session?.orchestratorTaskID ?? "").isEmpty)
                ? .available : .unavailable(reason: "A managed session with a stable task ID is required to stop it.")
            return WorkflowRunRole(id: item.sessionID, phaseID: item.phase ?? "Unassigned",
                                   name: item.agentType ?? "Agent", title: session?.title ?? item.taskID ?? item.sessionID,
                                   sessionID: item.sessionID, state: roleState(item.state),
                                   health: item.connected ? .healthy : .disconnected, healthDetail: nil,
                                   provider: item.provider, model: item.model, costUSD: nil, context: nil,
                                   startedAt: nil, updatedAt: session?.lastChange, finishedAt: nil,
                                   focusAvailability: canFocus, stopAvailability: canStop)
        }
        return .init(id: run.runID, title: run.workflowID, formationName: run.workflowID,
                     state: roles.contains(where: { $0.state.needsAttention }) ? .waiting : .running,
                     statusDetail: "Live daemon summary", phases: phases, roles: roles,
                     startedAt: nil, updatedAt: Date(), finishedAt: nil, budgetUSD: nil, costUSD: nil)
    }

    static func sessionID(forRoleID id: String, model: AppModel) -> String? {
        model.sessions.contains(where: { $0.id == id }) ? id : nil
    }

    private static func historyState(_ state: AgentState) -> HistoryRunState {
        switch state { case .error: return .failed; case .idle: return .completed; default: return .interrupted }
    }
    private static func roleState(_ state: AgentState) -> WorkflowRunRoleState {
        switch state {
        case .idle, .done: return .completed
        case .thinking, .running, .compacting: return .working
        case .waiting: return .waiting; case .approval: return .approval; case .error: return .failed
        }
    }
}
