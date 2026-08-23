// FocalPoint menu-bar app — workflow launcher (WORKFLOWS-PROPOSAL.md §8.2).
//
// Lists formation packages installed under ~/.config/focalpoint/workflows/
// and starts one. The architectural boundary is deliberate and load-bearing:
// the app CANNOT run a formation itself. It launches exactly ONE agent — the
// formation's orchestrator — via the daemon's `launch-session` primitive, and
// that orchestrator validates, expands, and sequences the crew (spec §3, §5.2).
// The app never expands a manifest into launch calls and never creates
// channels. Preflight records explicit provider/model choices as reviewed data;
// the orchestrator revalidates and materializes them through current APIs.
//
// Manifests are read with the small TOML subset parser in
// WorkflowFormationCore.swift — swiftc-only build means no package
// dependencies, and the schema (docs/workflows-schema.md) uses a narrow slice
// of TOML: tables, arrays of tables, strings, integers, booleans, and string
// arrays.
// MIT License.

import SwiftUI
import AppKit
import Combine

// MARK: - Launcher model

@MainActor
final class WorkflowLauncherModel: ObservableObject {

    @Published private(set) var packages: [FormationPackage] = []
    /// Bundled formations not yet installed under the user's config root.
    @Published private(set) var bundledPackages: [FormationPackage] = []
    @Published private(set) var issues: [FormationIssue] = []
    /// False until the first scan lands — keeps "No Workflows Installed"
    /// from flashing for a frame in front of a populated directory.
    @Published private(set) var hasScanned = false
    /// Directory id of the package whose launch request is in flight, if any.
    /// While set, all menu items are disabled: two clicks must never mint two
    /// orchestrators for one gesture.
    @Published private(set) var launchInFlightID: String?
    @Published private(set) var outcome: LaunchOutcome?
    @Published private(set) var catalogOutcome: CatalogOutcome?

    enum LaunchOutcome: Equatable {
        case launched(package: String, detail: String)
        case failed(package: String, detail: String)
    }

    enum CatalogOutcome: Equatable {
        case installed(package: String, detail: String)
        case failed(package: String, detail: String)
    }

    /// Own client for one-shot requests, following the DaemonClient pattern:
    /// no subscribe stream, just request/response on a short-lived connection.
    /// Kept off AppModel so this feature touches no file outside its lane.
    private let client = DaemonClient()

    /// FocalPoint configuration root ($XDG_CONFIG_HOME/focalpoint, else
    /// ~/.config/focalpoint). Workflows and agent types are siblings beneath it.
    nonisolated static var configRoot: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
                .appendingPathComponent("focalpoint", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/focalpoint", isDirectory: true)
    }

    /// Where formation packages live. Mirrors the daemon's config-root rule
    /// ($XDG_CONFIG_HOME/focalpoint, else ~/.config/focalpoint).
    nonisolated static var workflowsDirectory: URL {
        configRoot.appendingPathComponent("workflows", isDirectory: true)
    }

    /// Installed agent types, sibling of `workflowsDirectory`.
    nonisolated static var agentsDirectory: URL {
        configRoot.appendingPathComponent("agents", isDirectory: true)
    }

    /// Bundled packages ship as app resources and remain separate from user
    /// configuration until an explicit catalog install copies them there.
    nonisolated static var bundledCatalogDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("BundledPackages", isDirectory: true)
    }

    nonisolated static var bundledWorkflowsDirectory: URL? {
        bundledCatalogDirectory?.appendingPathComponent("workflows", isDirectory: true)
    }

    /// Non-nil when an agent type declares an `[enforced]` table, which the
    /// launch path cannot deliver — see the call site in `checkRole`.
    ///
    /// A missing or unreadable type file is *not* treated as a refusal here:
    /// the role's own `type` resolution is the orchestrator's job, and failing
    /// a formation because a type is not installed locally would be a
    /// different (and wrong) error. Only a type that is present and demands
    /// enforcement blocks the launch.
    nonisolated static func enforcedTierReason(forType type: String) -> String? {
        // Reject path separators before touching the filesystem: a type name
        // is a directory name under agentsDirectory, never a traversal.
        guard !type.contains("/"), type != "..", type != "." else {
            return "invalid agent type name '\(type)'"
        }
        let typeFile = agentsDirectory
            .appendingPathComponent(type, isDirectory: true)
            .appendingPathComponent("type.toml")
        guard let text = try? String(contentsOf: typeFile, encoding: .utf8) else { return nil }
        guard case .success(let root) = TomlParser.parse(text) else { return nil }
        guard case .table(let enforced)? = root["enforced"], !enforced.isEmpty else { return nil }
        let fields = enforced.keys.sorted().joined(separator: ", ")
        return "agent type '\(type)' declares [enforced] (\(fields)), which nothing delivers; "
             + "FocalPoint refuses rather than honoring it as prompt text only"
    }

    // MARK: Scanning

    func refresh() {
        let directory = Self.workflowsDirectory
        let bundledDirectory = Self.bundledWorkflowsDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.scan(directory: directory)
            let bundled = bundledDirectory.map { Self.scan(directory: $0) }
            let installedIDs = Set(result.packages.map(\.id))
            let bundledOnly = bundled?.packages.filter { !installedIDs.contains($0.id) } ?? []
            Task { @MainActor [weak self] in
                self?.packages = result.packages
                self?.bundledPackages = bundledOnly
                self?.issues = result.issues
                self?.hasScanned = true
            }
        }
    }

    /// The UI must call this only after its explicit confirmation dialog. The
    /// core installer rejects every collision and never overwrites a package.
    func installBundledFormation(_ package: FormationPackage) {
        guard let sourceRoot = Self.bundledCatalogDirectory else {
            catalogOutcome = .failed(package: package.name,
                                     detail: "Bundled catalog resources are unavailable.")
            return
        }
        let planning = BundledCatalogInstallPlan.formation(
            name: package.id, sourceRoot: sourceRoot, configRoot: Self.configRoot,
            referencedAgentTypes: package.referencedAgentTypes
        )
        guard case .success(let plan) = planning else {
            if case .failure(let error) = planning {
                catalogOutcome = .failed(package: package.name, detail: error)
            } else {
                catalogOutcome = .failed(package: package.name,
                                         detail: "Could not plan bundled formation installation.")
            }
            return
        }
        switch plan.install() {
        case .success:
            log("workflow launcher installed bundled formation \(boundedLogField(package.name))")
            catalogOutcome = .installed(
                package: package.name,
                detail: "Copied workflow and \(package.referencedAgentTypes.count) agent type\(package.referencedAgentTypes.count == 1 ? "" : "s")"
            )
            refresh()
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self,
                      case .installed(let name, _) = self.catalogOutcome,
                      name == package.name else { return }
                self.catalogOutcome = nil
            }
        case .failure(let error):
            catalogOutcome = .failed(package: package.name, detail: error)
        }
    }

    func dismissCatalogOutcome() { catalogOutcome = nil }

    /// Filesystem scan + manifest load. Missing workflows directory means
    /// "nothing installed", not an error.
    nonisolated private static func scan(directory: URL)
        -> (packages: [FormationPackage], issues: [FormationIssue])
    {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        var packages: [FormationPackage] = []
        var issues: [FormationIssue] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                continue   // stray files (READMEs, .DS_Store) are not packages
            }
            let dirName = entry.lastPathComponent
            let manifestURL = entry.appendingPathComponent("formation.toml")
            func issue(_ message: String) {
                issues.append(FormationIssue(directoryName: dirName, message: message, directoryURL: entry))
            }
            guard fm.fileExists(atPath: manifestURL.path) else {
                issue("missing formation.toml")
                continue
            }
            guard let text = try? String(contentsOf: manifestURL, encoding: .utf8) else {
                issue("formation.toml is not readable UTF-8")
                continue
            }
            switch TomlParser.parse(text) {
            case .failure(let error):
                issue("formation.toml line \(error.line): \(error.message)")
            case .success(let root):
                switch FormationManifestValidator.validate(
                    root: root, directory: entry, enforcedTierReason: Self.enforcedTierReason
                ) {
                case .failure(let error):
                    issue(error.message)
                case .success(let package):
                    packages.append(package)
                }
            }
        }
        return (packages, issues)
    }

    // MARK: Launching

    /// Start one formation: launch its orchestrator via the daemon's
    /// `launch-session` primitive (PROTOCOL.md §3/§4). Everything after this —
    /// revalidation, worktree prep, channel creation, role launch calls, and
    /// fan-out gates — happens inside that orchestrator agent. The app passes
    /// reviewed assignments but never expands them into launch calls itself.
    ///
    /// The configuration comes only from the explicit preflight. In
    /// particular, cwd/provider/model are concrete values; this method never
    /// consults focused-session or last-used defaults.
    func start(_ package: FormationPackage, configuration: WorkflowLaunchConfiguration) {
        guard launchInFlightID == nil else { return }
        let targetCwd = configuration.projectDirectory.path
        let configurationErrors = WorkflowPreflightValidation.errors(
            projectDirectory: configuration.projectDirectory,
            orchestratorModel: configuration.orchestratorModel,
            assignments: configuration.roleAssignments,
            fanoutLimit: configuration.fanoutLimit,
            fanoutCeiling: package.fanoutCeiling,
            unresolvedTypes: []
        )
        guard configurationErrors.isEmpty else {
            outcome = .failed(package: package.name, detail: configurationErrors.joined(separator: " "))
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetCwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            outcome = .failed(package: package.name,
                              detail: "Target directory no longer exists: \(targetCwd)")
            return
        }
        launchInFlightID = package.id
        outcome = nil

        let taskID = Self.mintTaskID(for: package)
        let request: [String: Any] = [
            "cmd": "launch-session",
            "agent_type": "workflow-orchestrator",
            "provider": configuration.orchestratorProvider.rawValue,
            "model": configuration.orchestratorModel,
            "cwd": targetCwd,
            "task": Self.orchestratorTask(for: package, configuration: configuration),
            "task_id": taskID,
            "title": "\(package.name) orchestrator",
            "role": "orchestrator",
            "workflow_id": package.id,
            "workflow_run_id": taskID,
            "workflow_phase": "orchestration",
            "workflow_gate": "authorized",
            "workflow_fanout": false,
            "workflow_assignments": configuration.daemonAssignmentManifest,
        ]
        log("workflow launch requested package=\(boundedLogField(package.name)) task_id=\(boundedLogField(taskID)) provider=\(configuration.orchestratorProvider.rawValue) model=\(boundedLogField(configuration.orchestratorModel)) cwd=\(boundedLogField(targetCwd))")

        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The daemon replies on terminal-open acceptance, which is quick;
            // crew expansion is the orchestrator's asynchronous business and
            // is NOT awaited here.
            let response = client.request(request, timeout: 5)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.launchInFlightID = nil
                if let response, response["ok"] as? Bool == true {
                    let slot = (response["slot"] as? NSNumber)?.intValue
                    let detail = slot.map { "orchestrator opening on key \($0)" }
                        ?? "orchestrator session opening"
                    self.outcome = .launched(package: package.name, detail: detail)
                    log("workflow launch accepted package=\(boundedLogField(package.name)) slot=\(slot.map(String.init) ?? "-")")
                    // The session row itself is the durable confirmation; the
                    // transient note clears once the row has had time to appear.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                        guard let self,
                              case .launched(let name, _) = self.outcome,
                              name == package.name else { return }
                        self.outcome = nil
                    }
                } else {
                    let message = (response?["error"] as? String)
                        ?? "Could not reach the FocalPoint daemon."
                    self.outcome = .failed(package: package.name,
                                           detail: String(message.prefix(240)))
                    log("workflow launch failed package=\(boundedLogField(package.name)) error=\(boundedLogField(message))")
                }
            }
        }
    }

    func dismissOutcome() { outcome = nil }

    /// Stable task id for this run of the formation: unique per run (each run
    /// is a distinct crew, and grouping keys on the orchestrator's task id),
    /// within the daemon's 1–64 char / [A-Za-z0-9._-] rule. The in-flight
    /// guard above, not id reuse, is the double-click protection.
    private static func mintTaskID(for package: FormationPackage) -> String {
        let sanitized = package.name.map { c -> Character in
            (c.isASCII && (c.isLetter || c.isNumber) || c == "." || c == "_" || c == "-") ? c : "-"
        }
        let base = String(String(sanitized).prefix(40))
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return "wf-\(base)-\(suffix)"
    }

    /// The typed instruction §8.2 is a shortcut for: "run this formation".
    /// Expansion judgment is delegated wholesale to the orchestrator agent;
    /// the task names the manifest, the target, and the rules, nothing more.
    private static func orchestratorTask(for package: FormationPackage,
                                         configuration: WorkflowLaunchConfiguration) -> String {
        let assignments = configuration.roleAssignments.map { assignment in
            let phase = assignment.phaseName ?? "main"
            let limit = assignment.fanoutMaximum.map {
                min($0, configuration.fanoutLimit ?? $0)
            } ?? 1
            return "- assignment=\(assignment.id) \(assignment.roleName) [type=\(assignment.typeName), phase=\(phase), gate=\(assignment.gate.rawValue), limit=\(limit)]: provider=\(assignment.provider.rawValue), model=\(assignment.model)"
        }.joined(separator: "\n")
        let fanout = configuration.fanoutLimit.map {
            "The human set a dynamic fan-out limit of \($0), which may only reduce the manifest ceiling."
        } ?? "This formation has no dynamic fan-out override."
        return """
        Run the FocalPoint formation "\(package.name)". Manifest: \(package.manifestURL.path). Agent types live in ~/.config/focalpoint/agents/.

        The human explicitly selected and finally confirmed target directory: \(configuration.projectDirectory.path). The preflight classified this formation as \(configuration.complexity.rawValue) complexity. Do not substitute a focused directory or last-used provider/model.

        The human reviewed these explicit role assignments:
        \(assignments)
        \(fanout)

        You are this formation's orchestrator (launched role=orchestrator; your stable task id is in the launch preamble). Work the focalpoint-orchestrator skill end to end:
        1. Revalidate the manifest and agent types, then use the explicit provider/model assignments above; refuse if a provider cannot deliver a declared capability or enforcement constraint.
        2. Prepare each role's working directory, wait for your own attachment to verify, then create the crew channel.
        3. Launch each role with its exact --workflow-assignment id plus the recorded workflow run, phase, gate, type, provider, and model. Also pass --role worker --manager-task-id <your task id> --channel <id>, and wait for verified attachments. The daemon rejects every deviation and enforces each assignment's launch limit.
        4. Honor every phase gate. The final preflight authorized only the formation and phases marked authorized; it did not pre-approve confirm gates. For a confirm gate, ask the human to approve that run and phase in the app, then retry without supplying any confirmation token. Never auto-approve, never silently retry, and on partial failure report to the human instead of stopping successful roles.

        The daemon validates the persisted assignment ledger, approval consumption, and individual launch/channel/stop calls; sequencing judgment remains yours.
        """
    }

    // MARK: Folder conveniences

    /// Open the workflows directory in Finder, creating it first if needed so
    /// the empty state has somewhere real to point at.
    func openWorkflowsFolder() {
        let directory = Self.workflowsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSWorkspace.shared.open(directory)
    }

    func reveal(_ issue: FormationIssue) {
        NSWorkspace.shared.activateFileViewerSelecting([issue.directoryURL])
    }
}

// MARK: - Menu-bar section view

/// The "Start Workflow" row of the dropdown panel: a submenu listing the
/// installed formations, plus honest inline status (offline, launching,
/// launch failed, malformed packages). Visual language matches the rest of
/// MenuContentView: Metrics.hPad margins, caption/callout type, footer-style
/// borderless controls.
struct WorkflowLauncherSection: View {
    @ObservedObject var launcher: WorkflowLauncherModel
    let daemonConnected: Bool
    /// A convenience displayed in preflight only. It is never selected unless
    /// the human explicitly presses "Select This Folder".
    let targetCwd: String
    @State private var preflightPackage: FormationPackage?
    @State private var bundledInstall: FormationPackage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                startMenu
                if !daemonConnected {
                    Text("Daemon offline")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                if !launcher.issues.isEmpty {
                    Label("\(launcher.issues.count)", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help(launcher.issues
                            .map { "\($0.directoryName): \($0.message)" }
                            .joined(separator: "\n"))
                }
            }
            if let launchingName {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Launching \(launchingName) orchestrator\u{2026}")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let outcome = launcher.outcome {
                outcomeLine(outcome)
            }
            if let outcome = launcher.catalogOutcome {
                catalogOutcomeLine(outcome)
            }
        }
        .padding(.horizontal, Metrics.hPad)
        .padding(.vertical, 8)
        .onAppear { launcher.refresh() }
        .alert(item: $bundledInstall) { package in
            Alert(
                title: Text("Install bundled workflow?"),
                message: Text(Self.bundledInstallConfirmation(for: package)),
                primaryButton: .default(Text("Install")) {
                    launcher.installBundledFormation(package)
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $preflightPackage) { package in
            WorkflowLaunchPreflightView(
                package: package,
                suggestedDirectory: URL(fileURLWithPath: targetCwd, isDirectory: true),
                daemonConnected: daemonConnected
            ) { configuration in
                launcher.start(package, configuration: configuration)
            }
        }
    }

    private var launchingName: String? {
        guard let id = launcher.launchInFlightID else { return nil }
        return launcher.packages.first(where: { $0.id == id })?.name ?? id
    }

    private var startMenu: some View {
        Menu {
            menuContent
        } label: {
            Label("Start Workflow", systemImage: "person.3.sequence")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .font(.callout)
        .help(daemonConnected
              ? "Launch one orchestrator agent for an installed formation — the orchestrator expands and runs the crew"
              : "The daemon is offline, so workflows can't be launched — installed packages are still listed")
    }

    @ViewBuilder
    private var menuContent: some View {
        Text("Project folder is chosen in preflight")
        if !launcher.hasScanned {
            Text("Scanning\u{2026}")
        } else if launcher.packages.isEmpty && launcher.bundledPackages.isEmpty && launcher.issues.isEmpty {
            Text("No Workflows Installed")
            Text("Install a bundled workflow below or add one to \(Self.shortPath(WorkflowLauncherModel.workflowsDirectory))")
        } else {
            if !launcher.packages.isEmpty {
                Text("Installed")
                ForEach(launcher.packages) { package in
                    Button {
                        preflightPackage = package
                    } label: {
                        Label("\(package.name) · \(package.menuDetail)",
                              systemImage: "person.3.sequence")
                    }
                    .disabled(!daemonConnected || launcher.launchInFlightID != nil)
                }
            }
            if !launcher.bundledPackages.isEmpty {
                if !launcher.packages.isEmpty { Divider() }
                Text("Bundled Catalog")
                ForEach(launcher.bundledPackages) { package in
                    Button {
                        bundledInstall = package
                    } label: {
                        Label("\(package.name) · \(package.menuDetail)",
                              systemImage: "shippingbox")
                    }
                    .disabled(launcher.launchInFlightID != nil)
                }
            }
            if !launcher.issues.isEmpty {
                Divider()
                ForEach(launcher.issues) { issue in
                    Button {
                        launcher.reveal(issue)
                    } label: {
                        Label("\(issue.directoryName): \(issue.message)",
                              systemImage: "exclamationmark.triangle")
                    }
                }
            }
            if !daemonConnected {
                Divider()
                Text("Daemon Offline — Start Unavailable")
            }
        }
        Divider()
        Button("Refresh") { launcher.refresh() }
        Button("Open Workflows Folder\u{2026}") { launcher.openWorkflowsFolder() }
        Button("Workflow Editor\u{2026}") { WorkflowEditorWindow.shared.show() }
    }

    private static func bundledInstallConfirmation(for package: FormationPackage) -> String {
        let types = package.referencedAgentTypes.joined(separator: ", ")
        return """
        This copies workflow '\(package.name)' and its referenced agent types (\(types)) into your FocalPoint configuration. Existing package directories are never overwritten; installation stops if any collide.
        """
    }

    @ViewBuilder
    private func catalogOutcomeLine(_ outcome: WorkflowLauncherModel.CatalogOutcome) -> some View {
        switch outcome {
        case .installed(let name, let detail):
            Label("\(name): \(detail)", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .failed(let name, let detail):
            HStack(alignment: .top, spacing: 5) {
                Label("\(name): \(detail)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Spacer(minLength: 2)
                Button { launcher.dismissCatalogOutcome() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
    }

    @ViewBuilder
    private func outcomeLine(_ outcome: WorkflowLauncherModel.LaunchOutcome) -> some View {
        switch outcome {
        case .launched(let name, let detail):
            Label("\(name): \(detail)", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        case .failed(let name, let detail):
            HStack(alignment: .top, spacing: 5) {
                Label("\(name): \(detail)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                Spacer(minLength: 2)
                Button { launcher.dismissOutcome() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
    }

    private static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
