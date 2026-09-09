// FocalPoint setup diagnostics — first-run and repeatable SwiftUI surfaces.
// MIT License.

import AppKit
import SwiftUI

enum SetupDiagnosticsPresentationMode: Sendable {
    case firstRun
    case diagnostics
}

@MainActor
final class SetupDiagnosticsController: ObservableObject {
    @Published private(set) var results: [SetupDiagnosticID: SetupDiagnosticResult]
    @Published private(set) var actionMessage: String?

    private let checks: [any SetupDiagnosticChecking]
    private let actionPerformer: any SetupDiagnosticActionPerforming

    init(checks: [any SetupDiagnosticChecking] = LocalSetupDiagnostics.checks(),
         actionPerformer: any SetupDiagnosticActionPerforming = LocalSetupDiagnosticActionPerformer()) {
        self.checks = checks
        self.actionPerformer = actionPerformer
        self.results = Dictionary(uniqueKeysWithValues: SetupDiagnosticID.allCases.map {
            ($0, SetupDiagnosticResult.pending($0))
        })
    }

    var orderedResults: [SetupDiagnosticResult] {
        SetupDiagnosticID.allCases.compactMap { results[$0] }
    }

    var isRunning: Bool { results.values.contains { $0.status == .running } }

    var readinessSummary: String {
        let values = results.values
        let ready = values.filter { $0.status == .passed }.count
        let attention = values.filter { $0.status == .failed }.count
        if attention > 0 { return "\(attention) check\(attention == 1 ? "" : "s") need attention" }
        if ready == SetupDiagnosticID.allCases.count { return "Setup looks ready" }
        return "\(ready) of \(SetupDiagnosticID.allCases.count) checks ready"
    }

    func runAll() async {
        actionMessage = nil
        for check in checks { results[check.id] = .running(check.id) }
        await withTaskGroup(of: SetupDiagnosticResult.self) { group in
            for check in checks {
                group.addTask { await check.run() }
            }
            for await result in group { results[result.id] = result }
        }
    }

    func run(_ id: SetupDiagnosticID) async {
        guard let check = checks.first(where: { $0.id == id }) else { return }
        results[id] = .running(id)
        results[id] = await check.run()
    }

    func perform(_ action: SetupDiagnosticAction, for id: SetupDiagnosticID) async {
        actionMessage = nil
        let outcome = await actionPerformer.perform(action)
        actionMessage = outcome.message
        if outcome.shouldRecheck { await run(id) }
    }

    func copyReport() {
        let report = SetupDiagnosticsReport.text(results: orderedResults)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        actionMessage = "Copied redacted diagnostics. No secrets or raw configuration were included."
    }

    func openGitHubIssue() async {
        actionMessage = "Collecting and redacting recent operational logs…"
        let setupResults = orderedResults
        let report = await Task.detached(priority: .userInitiated) {
            SupportDiagnosticsReport.collect(setupResults: setupResults)
        }.value
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        guard let url = SupportDiagnosticsReport.issueURL(report: report),
              NSWorkspace.shared.open(url) else {
            actionMessage = "Copied the redacted support report, but could not open GitHub."
            return
        }
        actionMessage = "Opened a prefilled GitHub issue. The complete redacted report is on your clipboard."
    }
}

@MainActor
struct SetupDiagnosticsView: View {
    let mode: SetupDiagnosticsPresentationMode
    let onFinished: (() -> Void)?
    @StateObject private var controller: SetupDiagnosticsController

    init(mode: SetupDiagnosticsPresentationMode = .diagnostics,
         controller: SetupDiagnosticsController? = nil,
         onFinished: (() -> Void)? = nil) {
        self.mode = mode
        self.onFinished = onFinished
        _controller = StateObject(wrappedValue: controller ?? SetupDiagnosticsController())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(controller.orderedResults) { result in
                        SetupDiagnosticCard(result: result) { action in
                            Task { await controller.perform(action, for: result.id) }
                        }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 590, idealHeight: 680)
        .task { await controller.runAll() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: mode == .firstRun ? "checklist" : "stethoscope")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42)
            VStack(alignment: .leading, spacing: 5) {
                Text(mode == .firstRun ? "Welcome to FocalPoint" : "Setup Diagnostics")
                    .font(.title2.bold())
                Text(mode == .firstRun
                     ? "Let’s verify the local services and integrations. Nothing is changed unless you choose a fix."
                     : "Check local setup, apply safe fixes, and open a privacy-safe support issue.")
                    .foregroundStyle(.secondary)
                Text(controller.readinessSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(controller.results.values.contains { $0.status == .failed } ? .orange : .secondary)
            }
            Spacer()
            Button {
                Task { await controller.runAll() }
            } label: {
                Label("Run all", systemImage: "arrow.clockwise")
            }
            .disabled(controller.isRunning)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let message = controller.actionMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Reports contain statuses and coarse evidence only—not paths, config contents, environment values, or credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                controller.copyReport()
            } label: {
                Label("Copy redacted diagnostics", systemImage: "doc.on.doc")
            }
            if mode == .diagnostics {
                Button {
                    Task { await controller.openGitHubIssue() }
                } label: {
                    Label("Open GitHub issue", systemImage: "exclamationmark.bubble")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isRunning)
            }
            if mode == .firstRun {
                Button("Finish") {
                    SetupDiagnosticsWindowCoordinator.markFirstRunComplete()
                    onFinished?()
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.isRunning)
            }
        }
        .padding(16)
    }
}

private struct SetupDiagnosticCard: View {
    let result: SetupDiagnosticResult
    let onAction: (SetupDiagnosticAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: result.id.systemImage)
                    .foregroundStyle(statusColor)
                    .frame(width: 22)
                Text(result.id.title).font(.headline)
                Spacer()
                Label(result.status.label, systemImage: statusImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            Text(result.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !result.evidence.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(result.evidence) { evidence in
                        GridRow {
                            Text(evidence.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(evidence.value)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if !result.actions.isEmpty && result.status != .running {
                HStack(spacing: 8) {
                    ForEach(result.actions) { action in
                        if action.isPrimary {
                            Button(action.title) { onAction(action) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        } else {
                            Button(action.title) { onAction(action) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5)))
    }

    private var statusColor: Color {
        switch result.status {
        case .notRun: .secondary
        case .running: .blue
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }

    private var statusImage: String {
        switch result.status {
        case .notRun: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
}

/// Standalone integration point: app startup can call `presentFirstRunIfNeeded`,
/// while Settings can call `showDiagnostics`. It owns no shared app model.
@MainActor
final class SetupDiagnosticsWindowCoordinator {
    static let shared = SetupDiagnosticsWindowCoordinator()
    private static let firstRunKey = "SetupDiagnostics.didCompleteFirstRun.v1"
    private var windowController: NSWindowController?

    static var shouldPresentFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: firstRunKey)
    }

    static func markFirstRunComplete() {
        UserDefaults.standard.set(true, forKey: firstRunKey)
    }

    func presentFirstRunIfNeeded() {
        guard Self.shouldPresentFirstRun else { return }
        show(mode: .firstRun)
    }

    func showDiagnostics() {
        show(mode: .diagnostics)
    }

    private func show(mode: SetupDiagnosticsPresentationMode) {
        if let window = windowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = SetupDiagnosticsView(mode: mode) { [weak self] in
            self?.windowController?.close()
            self?.windowController = nil
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = mode == .firstRun ? "Set Up FocalPoint" : "FocalPoint Setup Diagnostics"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 680))
        window.center()
        window.isReleasedWhenClosed = false
        windowController = NSWindowController(window: window)
        NSApp.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
    }
}
