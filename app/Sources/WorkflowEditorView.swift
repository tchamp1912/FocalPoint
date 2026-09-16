// FocalPoint menu-bar app — workflow editor (view layer).
//
// Two package kinds: formations (phases, gates, roles, fan-out, escalation)
// and agent types (provider preferences, advisory/enforced tables, and the
// persona prompt itself). Since the window consolidation this file provides
// the editor's *detail column* (`WorkflowEditorDetailView`), hosted by
// MainWindowView's unified sidebar — the standalone Workflow Editor window
// no longer exists. Visual language follows the settings panes:
// settingsCard glass groups, caption/callout type. All load/save/validation
// logic lives in WorkflowEditor.swift; this file is layout and binding only.
// MIT License.

import SwiftUI
import AppKit

/// The workflow editor's detail column, hosted by MainWindowView's unified
/// sidebar. Owns the bundled-install and catalog-error alerts, which are
/// raised from the bundled detail views below.
struct WorkflowEditorDetailView: View {
    @ObservedObject var store: WorkflowEditorModel
    @State private var bundledInstall: BundledInstallRequest?
    @State private var catalogError: String?

    var body: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .alert(item: $bundledInstall) { request in
                Alert(
                    title: Text("Install bundled package?"),
                    message: Text(request.confirmationText),
                    primaryButton: .default(Text("Install")) {
                        let error: String?
                        switch request {
                        case .formation(let formation): error = store.installBundledFormation(formation)
                        case .agentType(let type): error = store.installBundledAgentType(type)
                        }
                        catalogError = error
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert("Couldn't install bundled package", isPresented: Binding(
                get: { catalogError != nil }, set: { if !$0 { catalogError = nil } }
            )) {
                Button("OK", role: .cancel) { catalogError = nil }
            } message: {
                Text(catalogError ?? "")
            }
    }

    // MARK: Detail routing

    @ViewBuilder
    private var detail: some View {
        switch store.selection {
        case .formation(let id):
            if let index = store.formations.firstIndex(where: { $0.id == id }) {
                FormationEditorView(formation: $store.formations[index], store: store)
            } else {
                placeholder("Select a workflow or agent type")
            }
        case .agentType(let id):
            if let index = store.agentTypes.firstIndex(where: { $0.id == id }) {
                AgentTypeEditorView(type: $store.agentTypes[index], store: store)
            } else {
                placeholder("Select a workflow or agent type")
            }
        case .bundledFormation(let id):
            if let formation = store.bundledFormations.first(where: { $0.id == id }) {
                BundledFormationView(formation: formation) { bundledInstall = .formation(formation) }
            } else {
                placeholder("Select a workflow or agent type")
            }
        case .bundledAgentType(let id):
            if let type = store.bundledAgentTypes.first(where: { $0.id == id }) {
                BundledAgentTypeView(type: type) { bundledInstall = .agentType(type) }
            } else {
                placeholder("Select a workflow or agent type")
            }
        case .broken(_, let id):
            if let package = store.broken.first(where: { $0.id == id }) {
                BrokenPackageView(package: package, store: store)
            } else {
                placeholder("Select a workflow or agent type")
            }
        case nil:
            if store.formations.isEmpty && store.agentTypes.isEmpty && store.broken.isEmpty {
                placeholder("No workflows installed", message:
                    store.bundledFormations.isEmpty && store.bundledAgentTypes.isEmpty
                    ? "Use + to create a workflow or agent type. Reload to check for available packages."
                    : "Select a package from the Bundled Catalog to preview and install it, or use + to create your own.")
            } else {
                placeholder("Select a workflow or agent type")
            }
        }
    }

    private func placeholder(_ text: String, message: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("Packages live under \(WorkflowEditorModel.configRoot.path)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: 420)
        .settingsCard()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.settingsPageInset)
    }
}

private enum BundledInstallRequest: Identifiable {
    case formation(EditableFormation)
    case agentType(EditableAgentType)

    var id: String {
        switch self {
        case .formation(let formation): return "formation-\(formation.id)"
        case .agentType(let type): return "agent-\(type.id)"
        }
    }

    var confirmationText: String {
        switch self {
        case .formation(let formation):
            let types = formation.referencedAgentTypes.joined(separator: ", ")
            return "This copies workflow '\(formation.name)' and its referenced agent types (\(types)) into your FocalPoint configuration. Existing package directories are never overwritten; installation stops if any collide."
        case .agentType(let type):
            return "This copies agent type '\(type.name)' into your FocalPoint configuration. Existing package directories are never overwritten."
        }
    }
}

private struct BundledFormationView: View {
    let formation: EditableFormation
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.settingsCardRhythm) {
            SettingsPageHeader(
                title: formation.name,
                subtitle: formation.description,
                symbol: "shippingbox"
            )
            EditorCard(title: "Will install") {
                Text("Workflow: \(formation.name)")
                Text("Agent types: \(formation.referencedAgentTypes.joined(separator: ", "))")
                Text("Installation requires confirmation and refuses every name collision; it never overwrites installed packages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            EditorCard(title: "Graph",
                       caption: "Phases, gates, and fan-out as the orchestrator will sequence them.") {
                let graph = WorkflowGraphModel.make(input: WorkflowGraphInput(draft: formation))
                WorkflowGraphView(graph: graph)
                    .frame(height: min(max(graph.contentSize.height + 8, 140), 340))
            }
            Button("Install bundled workflow…", action: install)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .settingsPageLayout()
    }
}

private struct BundledAgentTypeView: View {
    let type: EditableAgentType
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.settingsCardRhythm) {
            SettingsPageHeader(
                title: type.name,
                subtitle: type.description,
                symbol: "shippingbox"
            )
            EditorCard(title: "Will install") {
                Text("\(type.prefer.joined(separator: " › ")) · \(type.model)")
                Text("Installing requires confirmation and refuses existing package directories; it never overwrites them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button("Install bundled agent type…", action: install)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .settingsPageLayout()
    }
}

// MARK: - Shared editor chrome

/// Header above every editor: what is being edited, where it lives, and the
/// Save/Revert pair. Save is disabled while validation has errors or there
/// is nothing to save — the errors themselves are listed just below.
private struct EditorHeader: View {
    let title: String
    let subtitle: String
    let dirty: Bool
    let canSave: Bool
    let saveError: String?
    var onSave: () -> Void
    var onRevert: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline)
                if dirty {
                    Text("Edited")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                }
                Spacer()
                if dirty {
                    Button("Revert", action: onRevert)
                        .help("Discard unsaved changes")
                }
                Button("Save", action: onSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!dirty || !canSave)
                    .help(canSave
                          ? "Write the package back to disk (canonical TOML)"
                          : "Fix the errors listed below before saving")
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct DiagnosticsCard: View {
    let errors: [String]
    let warnings: [String]

    var body: some View {
        if !errors.isEmpty || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(errors, id: \.self) { message in
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
                ForEach(warnings, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard(.alert)
        }
    }
}

/// The editor's titled section card: the shared canonical settings-card
/// chrome plus a small title/caption header.
private struct EditorCard<Content: View>: View {
    let title: String
    let caption: String?
    @ViewBuilder var content: () -> Content

    init(title: String, caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCardHeader(title: title, subtitle: caption)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsCard()
    }
}

/// Editable list of short strings (escalation kinds, allow_paths, …).
private struct StringListEditor: View {
    let addLabel: String
    let placeholder: String
    @Binding var values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(values.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(placeholder, text: $values[index])
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    Button { values.remove(at: index) } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove")
                }
            }
            Button { values.append("") } label: {
                Label(addLabel, systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - Formation editor

private struct FormationEditorView: View {
    @Binding var formation: EditableFormation
    @ObservedObject var store: WorkflowEditorModel
    @State private var saveError: String?

    private var diagnostics: (errors: [String], warnings: [String]) {
        EditorValidation.formation(formation, installedTypes: store.installedTypeNames)
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(
                title: formation.name,
                subtitle: formation.directoryURL.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                dirty: store.isDirty(formation),
                canSave: diagnostics.errors.isEmpty,
                saveError: saveError,
                onSave: { saveError = store.saveFormation(formation) },
                onRevert: { store.revertFormation(formation); saveError = nil }
            )
            Divider()
            ScrollView(.vertical) {
                VStack(spacing: Metrics.settingsCardRhythm) {
                    DiagnosticsCard(errors: diagnostics.errors,
                                    warnings: diagnostics.warnings + formation.warnings)
                    packageCard
                    structureCard
                    graphCard
                    if formation.phased {
                        phasesEditor
                    } else {
                        EditorCard(title: "Roles",
                                   caption: "One fixed crew, launched together under the formation's orchestrator.") {
                            RoleListEditor(roles: $formation.roles,
                                           knownTypes: store.installedTypeNames)
                        }
                    }
                    escalateCard
                }
                .padding(Metrics.settingsPageInset)
            }
        }
    }

    private var packageCard: some View {
        EditorCard(title: "Package") {
            LabeledField("Name") {
                TextField("review-fanout", text: $formation.name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Description") {
                TextField("What this formation delivers", text: $formation.description)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Schema v1 · saving rewrites formation.toml in canonical form — hand-written comments are not preserved")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var structureCard: some View {
        EditorCard(title: "Structure",
                   caption: "Phases run in order under one orchestrator, each transition passing its gate. Single-phase launches one fixed crew. Switching keeps both drafts — nothing is discarded.") {
            Picker("Structure", selection: $formation.phased) {
                Text("Single-phase roles").tag(false)
                Text("Phases with gates").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    /// Live graph of the current draft, including while the draft is
    /// momentarily invalid (a dangling `after` mid-rename still draws).
    private var graphCard: some View {
        EditorCard(title: "Graph",
                   caption: "Phases, gates, and fan-out as the orchestrator will sequence them. Provider and model are chosen later, at launch preflight.") {
            let graph = WorkflowGraphModel.make(input: WorkflowGraphInput(draft: formation))
            WorkflowGraphView(graph: graph)
                .frame(height: min(max(graph.contentSize.height + 8, 140), 340))
        }
    }

    private var phasesEditor: some View {
        VStack(spacing: Metrics.settingsCardRhythm) {
            ForEach(formation.phases.indices, id: \.self) { index in
                PhaseCardView(
                    phase: $formation.phases[index],
                    isFirst: index == 0,
                    isLast: index == formation.phases.count - 1,
                    earlierPhases: Array(formation.phases[..<index].map(\.name)),
                    earlierRoles: formation.phases[..<index].flatMap { $0.roles.map(\.name) },
                    knownTypes: store.installedTypeNames,
                    onMove: { delta in movePhase(index, by: delta) },
                    onDelete: { formation.phases.remove(at: index) }
                )
            }
            Button { addPhase() } label: {
                Label("Add Phase", systemImage: "plus")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func addPhase() {
        let previous = formation.phases.last
        var phase = EditablePhase(id: UUID())
        phase.name = "phase-\(formation.phases.count + 1)"
        phase.after = previous?.name
        phase.gate = .confirm
        phase.roles = [EditableRole(id: UUID())]
        formation.phases.append(phase)
    }

    private func movePhase(_ index: Int, by delta: Int) {
        let target = index + delta
        guard formation.phases.indices.contains(index),
              formation.phases.indices.contains(target) else { return }
        formation.phases.swapAt(index, target)
    }

    private var escalateCard: some View {
        EditorCard(title: "Escalation & Completion",
                   caption: "Which channel messages and session states surface to the human, and when the formation counts as done. Completion is lifecycle policy — approval and error stay visible regardless.") {
            LabeledField("Channel kinds") {
                StringListEditor(addLabel: "Kind", placeholder: "blocker",
                                 values: $formation.escalate.channelKinds)
            }
            LabeledField("States") {
                StringListEditor(addLabel: "State", placeholder: "error",
                                 values: $formation.escalate.states)
            }
            LabeledField("Completion") {
                TextField("all-roles-done", text: $formation.escalate.completion)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

/// Labeled vertical field pair used across the editor cards.
private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Phase card (the gate editor)

private struct PhaseCardView: View {
    @Binding var phase: EditablePhase
    let isFirst: Bool
    let isLast: Bool
    let earlierPhases: [String]
    let earlierRoles: [String]
    let knownTypes: [String]
    var onMove: (Int) -> Void
    var onDelete: () -> Void

    var body: some View {
        EditorCard(title: "Phase") {
            HStack(spacing: 8) {
                TextField("phase-name", text: $phase.name)
                    .textFieldStyle(.roundedBorder)
                Button { onMove(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(isFirst).help("Move earlier")
                Button { onMove(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(isLast).help("Move later")
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Remove this phase")
            }

            LabeledField("Runs after") {
                Picker("Runs after", selection: $phase.after) {
                    Text("No dependency — starts immediately").tag(String?.none)
                    ForEach(earlierPhases, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                    if let after = phase.after, !earlierPhases.contains(after) {
                        Text("\(after) (missing — fix or reselect)").tag(String?.some(after))
                    }
                }
                .labelsHidden()
            }

            // The gate is the phase transition's human checkpoint — the
            // summary under the picker states plainly what each choice does.
            LabeledField("Gate — what happens before this phase starts") {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("Gate", selection: $phase.gate) {
                        ForEach(PhaseGate.allCases) { gate in
                            Text(gate.title).tag(gate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(phase.gate.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledField("Contents") {
                Picker("Contents", selection: $phase.useFanout) {
                    Text("Fixed roles").tag(false)
                    Text("Bounded fan-out").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if phase.useFanout {
                fanoutEditor
            } else {
                RoleListEditor(roles: $phase.roles, knownTypes: knownTypes)
            }
        }
    }

    private var fanoutEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The named role's untrusted output chooses only the slice count (up to max), slice names, and slice tasks. Type, ceiling, cwd root, and gate stay fixed here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            LabeledField("From role (its output names the slices)") {
                Picker("From", selection: $phase.fanout.from) {
                    if phase.fanout.from.isEmpty {
                        Text("Choose a role…").tag("")
                    }
                    ForEach(earlierRoles, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !phase.fanout.from.isEmpty && !earlierRoles.contains(phase.fanout.from) {
                        Text("\(phase.fanout.from) (not a role in an earlier phase)").tag(phase.fanout.from)
                    }
                }
                .labelsHidden()
            }

            LabeledField("Max slices") {
                Stepper(value: $phase.fanout.max, in: 1...12) {
                    Text("\(phase.fanout.max)")
                        .monospacedDigit()
                }
            }

            LabeledField("Agent type for every slice") {
                TypePicker(selection: $phase.fanout.type, knownTypes: knownTypes)
            }

            LabeledField("cwd root (every slice is prepared beneath it)") {
                TextField("worktrees/", text: $phase.fanout.cwdRoot)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}

// MARK: - Role editing (shared by single-phase and per-phase roles)

private struct RoleListEditor: View {
    @Binding var roles: [EditableRole]
    let knownTypes: [String]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(roles.indices, id: \.self) { index in
                RoleCardView(role: $roles[index], knownTypes: knownTypes) {
                    roles.remove(at: index)
                }
            }
            Button { roles.append(EditableRole(id: UUID())) } label: {
                Label("Add Role", systemImage: "plus")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RoleCardView: View {
    @Binding var role: EditableRole
    let knownTypes: [String]
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("role-name", text: $role.name)
                    .textFieldStyle(.roundedBorder)
                TypePicker(selection: $role.type, knownTypes: knownTypes)
                    .frame(maxWidth: 200)
                Button(action: onDelete) { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Remove this role")
            }
            HStack(spacing: 14) {
                Picker("Kind", selection: $role.kind) {
                    Text("Worker").tag(RoleKind.worker)
                    Text("Orchestrator").tag(RoleKind.orchestrator)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .help("An orchestrator launches first and owns the crew channel")
                Toggle("Prepare worktree", isOn: Binding(
                    get: { role.prep == "worktree" },
                    set: { role.prep = $0 ? "worktree" : "" }
                ))
                .toggleStyle(.checkbox)
                .help("prep = \"worktree\" — a request the orchestrator satisfies before launch, never a daemon command")
            }
            .font(.caption)
            LabeledField("Fixed task text (optional)") {
                TextEditor(text: $role.task)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 34, maxHeight: 90)
                    .padding(4)
                    .settingsInset()
            }
        }
        .padding(10)
        .settingsInset()
    }
}

/// Agent-type picker that stays honest about values not installed locally:
/// they remain selectable (marked) rather than being silently rewritten.
private struct TypePicker: View {
    @Binding var selection: String
    let knownTypes: [String]

    var body: some View {
        Picker("Agent type", selection: $selection) {
            if selection.isEmpty {
                Text("Choose…").tag("")
            }
            ForEach(knownTypes, id: \.self) { name in
                Text(name).tag(name)
            }
            if !selection.isEmpty && !knownTypes.contains(selection) {
                Text("\(selection) (not installed)").tag(selection)
            }
        }
        .labelsHidden()
    }
}

// MARK: - Agent-type editor

private struct AgentTypeEditorView: View {
    @Binding var type: EditableAgentType
    @ObservedObject var store: WorkflowEditorModel
    @State private var saveError: String?

    private var diagnostics: (errors: [String], warnings: [String]) {
        EditorValidation.agentType(type)
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(
                title: type.name,
                subtitle: type.directoryURL.path
                    .replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                dirty: store.isDirty(type),
                canSave: diagnostics.errors.isEmpty,
                saveError: saveError,
                onSave: { saveError = store.saveAgentType(type) },
                onRevert: { store.revertAgentType(type); saveError = nil }
            )
            Divider()
            ScrollView(.vertical) {
                VStack(spacing: Metrics.settingsCardRhythm) {
                    DiagnosticsCard(errors: diagnostics.errors,
                                    warnings: diagnostics.warnings + type.warnings)
                    identityCard
                    providerCard
                    advisoryCard
                    enforcedCard
                    personaCard
                }
                .padding(Metrics.settingsPageInset)
            }
        }
    }

    private var identityCard: some View {
        EditorCard(title: "Agent Type") {
            LabeledField("Name") {
                TextField("security-reviewer", text: $type.name)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Description") {
                TextField("What this agent is for", text: $type.description)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var providerCard: some View {
        EditorCard(title: "Provider",
                   caption: "Ordered preference — the launcher picks the first provider that can satisfy every requirement and enforced constraint.") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(type.prefer.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        Picker("Provider", selection: $type.prefer[index]) {
                            ForEach(WorkflowEditorModel.knownProviders, id: \.self) { provider in
                                Text(provider).tag(provider)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        Button { moveProvider(index, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(index == 0)
                        Button { moveProvider(index, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .disabled(index == type.prefer.count - 1)
                        Button { type.prefer.remove(at: index) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                Button {
                    let unused = WorkflowEditorModel.knownProviders.first { !type.prefer.contains($0) }
                    type.prefer.append(unused ?? "claude")
                } label: {
                    Label("Add provider", systemImage: "plus").font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(type.prefer.count >= WorkflowEditorModel.knownProviders.count)
            }
            LabeledField("Model (optional — provider default when empty)") {
                TextField("gpt-5.6-sol", text: $type.model)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Requires (checkable capabilities; 'channels' excludes Cursor attachable mode)") {
                StringListEditor(addLabel: "Capability", placeholder: "channels",
                                 values: $type.requires)
            }
        }
    }

    private var advisoryCard: some View {
        EditorCard(title: "Advisory",
                   caption: "Prompt text prepended to the task. It is not a permission, sandbox, or guarantee — the model can ignore it. Never treat these values as enforced.") {
            LabeledField("Scope") {
                TextField("Report findings; never modify source.", text: $type.advisoryScope)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Output shape") {
                TextField("Ranked list, most severe first, with file:line.", text: $type.advisoryOutput)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledField("Escalate as (channel message kind)") {
                TextField("blocker", text: $type.advisoryEscalateAs)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var enforcedCard: some View {
        EditorCard(title: "Enforced",
                   caption: "Guarantees the launcher must materialize through the provider's project-local enforcement surface before launch — and refuse the launch when it cannot. Unknown enforced fields are rejected by the schema.") {
            Toggle("Read-only — prevent source modification", isOn: $type.enforcedReadOnly)
                .toggleStyle(.checkbox)
            LabeledField("Allowed paths (relative to the prepared working directory)") {
                StringListEditor(addLabel: "Path", placeholder: ".",
                                 values: $type.allowPaths)
            }
        }
    }

    private var personaCard: some View {
        EditorCard(title: "Persona prompt",
                   caption: "The markdown file the persona is built from. Saved as \(type.personaPromptFile) next to type.toml.") {
            LabeledField("Title (the launch's display title)") {
                TextField("Security review", text: $type.personaTitle)
                    .textFieldStyle(.roundedBorder)
            }
            TextEditor(text: $type.personaMarkdown)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 200)
                .padding(4)
                .settingsInset()
        }
    }

    private func moveProvider(_ index: Int, by delta: Int) {
        let target = index + delta
        guard type.prefer.indices.contains(index),
              type.prefer.indices.contains(target) else { return }
        type.prefer.swapAt(index, target)
    }
}

// MARK: - Broken package detail

private struct BrokenPackageView: View {
    let package: BrokenPackage
    @ObservedObject var store: WorkflowEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.settingsCardRhythm) {
            Text("Malformed package").font(.caption).foregroundStyle(.secondary)
            Text(package.id).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Label(package.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text(package.directoryURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard(.alert)
            HStack(spacing: 12) {
                Button("Reveal in Finder") {
                    store.reveal(.broken(package.kind, package.id))
                }
                Button("Move to Trash", role: .destructive) {
                    store.delete(.broken(package.kind, package.id))
                }
            }
            .controlSize(.small)
            Text("Fix the manifest in your editor, then reload — or trash the package.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Metrics.settingsPageInset)
    }
}
