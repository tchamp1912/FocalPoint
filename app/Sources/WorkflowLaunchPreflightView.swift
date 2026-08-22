// FocalPoint menu-bar app — explicit workflow launch preflight.
// MIT License.

import SwiftUI
import AppKit

struct WorkflowLaunchPreflightView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var preflight: WorkflowLaunchPreflightModel
    let daemonConnected: Bool
    let onLaunch: (WorkflowLaunchConfiguration) -> Void

    init(package: FormationPackage, suggestedDirectory: URL?, daemonConnected: Bool,
         onLaunch: @escaping (WorkflowLaunchConfiguration) -> Void) {
        _preflight = StateObject(wrappedValue: WorkflowLaunchPreflightModel(
            package: package, suggestedDirectory: suggestedDirectory
        ))
        self.daemonConnected = daemonConnected
        self.onLaunch = onLaunch
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if preflight.isReviewingConfirmation {
                        confirmation
                    } else {
                        projectFolder
                        formationSummary
                        executionChoices
                        formationPlan
                        validation
                    }
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 620, idealHeight: 720)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "person.3.sequence.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(preflight.isReviewingConfirmation ? "Confirm workflow launch" : "Workflow preflight")
                    .font(.headline)
                Text(preflight.package.name)
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(preflight.complexity.title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .padding(18)
    }

    private var projectFolder: some View {
        preflightSection("Project folder", systemImage: "folder") {
            Text("Choose the exact project this formation may operate in. FocalPoint does not reuse a focused or last-used directory.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(preflight.projectDirectory.map(Self.shortPath) ?? "No folder selected")
                    .font(.callout.monospaced())
                    .foregroundStyle(preflight.projectDirectory == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseProjectFolder)
            }
            if preflight.projectDirectory == nil, let suggested = preflight.suggestedDirectory {
                HStack {
                    Text("Previously focused: \(Self.shortPath(suggested))")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Select This Folder") { selectSuggestedDirectory(suggested) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    private var formationSummary: some View {
        preflightSection("Formation", systemImage: "list.bullet.rectangle") {
            Text(preflight.package.description)
                .font(.callout)
            HStack(spacing: 14) {
                summaryChip(preflight.package.menuDetail, image: "person.2")
                summaryChip("Completion: \(preflight.package.completionPolicy)", image: "checkmark.circle")
            }
            Text(preflight.complexity.explanation)
                .font(.caption).foregroundStyle(.secondary)
            Text("Attention remains visible for: \(preflight.package.escalationStates.joined(separator: ", ")). Channel escalation: \(preflight.package.escalationKinds.joined(separator: ", ")).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var executionChoices: some View {
        preflightSection("Recommendations and overrides", systemImage: "slider.horizontal.3") {
            Text("Every launch uses the concrete choices shown here. Changing provider selects a fresh complexity-based model; no last-used provider default is inherited.")
                .font(.caption).foregroundStyle(.secondary)
            assignmentControls(
                title: "Formation orchestrator",
                subtitle: "Recommended for \(preflight.complexity.title.lowercased()) coordination",
                provider: Binding(
                    get: { preflight.orchestratorProvider },
                    set: { preflight.setOrchestratorProvider($0) }
                ),
                model: $preflight.orchestratorModel
            )
            Divider()
            ForEach(Array(preflight.roleAssignments.indices), id: \.self) { index in
                let assignment = preflight.roleAssignments[index]
                assignmentControls(
                    title: assignment.roleName,
                    subtitle: "\(assignment.typeName) · \(assignment.sourceDescription)",
                    provider: Binding(
                        get: { preflight.roleAssignments[index].provider },
                        set: { preflight.setRoleProvider($0, at: index) }
                    ),
                    model: Binding(
                        get: { preflight.roleAssignments[index].model },
                        set: { preflight.roleAssignments[index].model = $0; preflight.isReviewingConfirmation = false }
                    )
                )
                if index != preflight.roleAssignments.indices.last { Divider() }
            }
            if let ceiling = preflight.package.fanoutCeiling {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dynamic fan-out limit").font(.callout.weight(.medium))
                        Text("Manifest hard ceiling: \(ceiling). The plan cannot raise this override.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Stepper(value: Binding(
                        get: { preflight.fanoutLimit ?? 1 },
                        set: { preflight.fanoutLimit = $0; preflight.isReviewingConfirmation = false }
                    ), in: 1...ceiling) {
                        Text("\(preflight.fanoutLimit ?? 1)").monospacedDigit()
                    }
                    .fixedSize()
                }
            }
        }
    }

    private var formationPlan: some View {
        preflightSection("Roles, phases, and gates", systemImage: "point.3.connected.trianglepath.dotted") {
            if preflight.package.phases.isEmpty {
                Text("Single authorized phase")
                    .font(.callout.weight(.medium))
                ForEach(preflight.package.roles) { roleRow($0) }
            } else {
                ForEach(preflight.package.phases) { phase in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(phase.name).font(.callout.weight(.semibold))
                            if let after = phase.after {
                                Text("after \(after)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label(phase.gate.title,
                                  systemImage: phase.gate == .confirm ? "hand.raised.fill" : "checkmark.shield")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(phase.gate == .confirm ? .orange : .secondary)
                        }
                        Text(phase.gate.explanation)
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(phase.roles) { roleRow($0) }
                    }
                    .padding(10)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    @ViewBuilder
    private var validation: some View {
        if !preflight.validationErrors.isEmpty {
            preflightSection("Needs attention", systemImage: "exclamationmark.triangle.fill") {
                ForEach(preflight.validationErrors, id: \.self) { error in
                    Label(error, systemImage: "xmark.circle")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("One orchestrator session will open; it will materialize this formation and preserve every confirm gate.",
                  systemImage: "checkmark.shield.fill")
                .font(.callout)
            confirmationRow("Project", Self.shortPath(preflight.projectDirectory!))
            confirmationRow("Formation", "\(preflight.package.name) · \(preflight.package.menuDetail)")
            confirmationRow("Orchestrator", "\(preflight.orchestratorProvider.title) · \(preflight.orchestratorModel)")
            if let fanoutLimit = preflight.fanoutLimit {
                confirmationRow("Fan-out", "Up to \(fanoutLimit), with a mandatory human confirmation gate")
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Resolved crew").font(.callout.weight(.semibold))
                ForEach(preflight.roleAssignments) { assignment in
                    HStack {
                        Text(assignment.roleName)
                        Spacer()
                        Text("\(assignment.provider.title) · \(assignment.model)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            Text("Selecting “Confirm & Launch” authorizes the formation and its authorized phases only. Phases marked Confirm still require a separate human decision; FocalPoint never answers approvals or retries launches automatically.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(10)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
            Spacer()
            if preflight.isReviewingConfirmation {
                Button("Back") { preflight.isReviewingConfirmation = false }
                Button("Confirm & Launch") {
                    guard let configuration = preflight.makeConfiguration() else { return }
                    onLaunch(configuration)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!daemonConnected || !preflight.canContinue)
            } else {
                Button("Review Launch") { preflight.isReviewingConfirmation = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!daemonConnected || !preflight.canContinue)
            }
        }
        .padding(16)
    }

    private func assignmentControls(title: String, subtitle: String,
                                    provider: Binding<WorkflowLaunchProvider>,
                                    model: Binding<String>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Provider", selection: provider) {
                ForEach(WorkflowLaunchProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            .labelsHidden().frame(width: 125)
            TextField("Required model", text: model)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
        }
    }

    private func roleRow(_ role: FormationRoleSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: role.kind == "orchestrator" ? "person.badge.key" : "person")
                .foregroundStyle(.secondary).frame(width: 16)
            Text(role.displayName).font(.caption.weight(.medium))
            Text(role.type).font(.caption).foregroundStyle(.secondary)
            if let prep = role.prep { Text("· \(prep)").font(.caption2).foregroundStyle(.tertiary) }
            if let max = role.fanoutMaximum { Text("≤ \(max)").font(.caption2).foregroundStyle(.orange) }
            Spacer()
        }
    }

    private func confirmationRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption.weight(.semibold)).frame(width: 95, alignment: .leading)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private func summaryChip(_ text: String, image: String) -> some View {
        Label(text, systemImage: image)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quinary, in: Capsule())
    }

    private func preflightSection<Content: View>(_ title: String, systemImage: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Workflow Project"
        panel.prompt = "Choose Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            preflight.projectDirectory = url.standardizedFileURL
            preflight.isReviewingConfirmation = false
        }
    }

    private func selectSuggestedDirectory(_ url: URL) {
        preflight.projectDirectory = url.standardizedFileURL
        preflight.isReviewingConfirmation = false
    }

    private static func shortPath(_ url: URL) -> String {
        url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}
