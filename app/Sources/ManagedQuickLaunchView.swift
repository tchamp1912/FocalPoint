// FocalPoint menu-bar app — single managed-agent quick launcher.
// Integration is closure-based so this feature does not own navigation,
// daemon clients, or shared app state.
// MIT License.

import SwiftUI
import AppKit

struct ManagedQuickLaunchActions {
    var launch: (ManagedQuickLaunchRequest) -> Void
    var cancel: () -> Void
}

struct ManagedQuickLaunchView: View {
    let actions: ManagedQuickLaunchActions

    @State private var draft: ManagedQuickLaunchDraft
    @State private var issues: [ManagedQuickLaunchValidationIssue] = []
    @State private var confirmation: ManagedQuickLaunchRequest?
    @State private var presets: [ManagedQuickLaunchPreset]
    @State private var selectedPresetID = ""
    @State private var presetName = ""
    @State private var presetError: String?
    private let presetStore: ManagedQuickLaunchPresetStore

    init(initialCwd: String = "", actions: ManagedQuickLaunchActions,
         presetStore: ManagedQuickLaunchPresetStore = .init()) {
        self.actions = actions
        self.presetStore = presetStore
        var initial = ManagedQuickLaunchDraft()
        initial.cwd = initialCwd
        _draft = State(initialValue: initial)
        _presets = State(initialValue: presetStore.presets)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                taskSection
                destinationSection
                identitySection
                recommendationSection
                presetsSection
                validationSummary
                footer
            }
            .padding(22)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 700)
        .sheet(item: $confirmation) { request in
            confirmationView(request)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Launch Managed Agent").font(.title2).bold()
            Text("Review every launch choice, then confirm one managed worker session.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var taskSection: some View {
        GroupBox("Task") {
            TextEditor(text: $draft.task)
                .font(.body)
                .frame(minHeight: 110)
                .overlay(alignment: .topLeading) {
                    if draft.task.isEmpty {
                        Text("Describe the exact work and completion criteria…")
                            .foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
            fieldIssue(.task)
        }
    }

    private var destinationSection: some View {
        GroupBox("Project") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("/absolute/project/folder", text: $draft.cwd)
                    Button("Choose Folder…", action: chooseFolder)
                }
                Text("The selected folder is passed explicitly as cwd; no active-window or recent-project inference is used.")
                    .font(.caption).foregroundStyle(.secondary)
                fieldIssue(.cwd)
            }
        }
    }

    private var identitySection: some View {
        GroupBox("Agent and identity") {
            VStack(alignment: .leading, spacing: 11) {
                LabeledContent("Agent type") {
                    TextField("Automatic from task", text: $draft.agentType).frame(width: 280)
                }
                fieldIssue(.agentType)
                LabeledContent("Provider") {
                    Picker("Provider", selection: $draft.provider) {
                        ForEach(ManagedQuickLaunchProvider.allCases) { Text($0.displayName).tag($0) }
                    }.labelsHidden().frame(width: 280)
                }
                LabeledContent("Explicit model") {
                    TextField("Automatic from task", text: $draft.model).frame(width: 280)
                }
                Text("Leave both agent type and model blank to resolve them from this task. Every confirmed launch contains concrete values; provider defaults and last-used settings are never used.")
                    .font(.caption).foregroundStyle(.secondary)
                fieldIssue(.model)
                LabeledContent("Title") {
                    TextField("Human-readable terminal title", text: $draft.title).frame(width: 280)
                }
                fieldIssue(.title)
                LabeledContent("Unique task ID") {
                    HStack {
                        TextField("stable-task-id", text: $draft.taskID).frame(width: 220)
                        Button("Regenerate") {
                            draft.taskID = ManagedQuickLaunchRules.mintTaskID(prefix: draft.title)
                        }
                    }
                }
                fieldIssue(.taskID)
            }
        }
    }

    private var recommendationSection: some View {
        let recommendation = ManagedQuickLaunchRules.recommendation(for: draft)
        return GroupBox("Complexity and recommendation") {
            VStack(alignment: .leading, spacing: 9) {
                Picker("Complexity", selection: $draft.complexity) {
                    ForEach(ManagedQuickLaunchComplexity.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if draft.complexity == .infer {
                    Text("Inferred as \(recommendation.complexity.displayName.lowercased()) from the task text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.agentType.isEmpty && draft.model.isEmpty {
                    Text("This recommendation will be applied automatically when you review the launch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recommended: \(recommendation.agentType) · \(recommendation.provider.displayName) · \(recommendation.model)")
                            .font(.callout).bold()
                        Text(recommendation.rationale).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Apply Recommendation") {
                        draft.agentType = recommendation.agentType
                        draft.provider = recommendation.provider
                        draft.model = recommendation.model
                    }
                }
            }
        }
    }

    private var presetsSection: some View {
        GroupBox("Named presets") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Preset", selection: $selectedPresetID) {
                        Text("Choose a preset…").tag("")
                        ForEach(presets) { Text($0.name).tag($0.id) }
                    }
                    Button("Load") { loadPreset() }.disabled(selectedPresetID.isEmpty)
                    Button("Delete", role: .destructive) { deletePreset() }.disabled(selectedPresetID.isEmpty)
                }
                HStack {
                    TextField("New preset name", text: $presetName)
                    Button("Save Current Settings") { savePreset() }
                }
                Text("Presets save folder, agent type, provider, explicit model, title, and complexity. Task text and task ID are never persisted.")
                    .font(.caption).foregroundStyle(.secondary)
                if let presetError { Text(presetError).font(.caption).foregroundStyle(.red) }
            }
        }
    }

    @ViewBuilder private var validationSummary: some View {
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label("Resolve \(issues.count) field issue\(issues.count == 1 ? "" : "s") before review.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                ForEach(issues) { Text("• \($0.message)").font(.caption) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: actions.cancel)
            Spacer()
            Button("Review Launch") { review() }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func fieldIssue(_ field: ManagedQuickLaunchValidationIssue.Field) -> some View {
        if let issue = issues.first(where: { $0.field == field }) {
            Text(issue.message).font(.caption).foregroundStyle(.red)
        }
    }

    private func confirmationView(_ request: ManagedQuickLaunchRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Confirm managed launch").font(.title2).bold()
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                confirmationRow("Project", request.cwd)
                confirmationRow("Agent", request.agentType)
                confirmationRow("Provider", request.provider.displayName)
                confirmationRow("Model", request.model)
                confirmationRow("Complexity", request.complexity.displayName)
                confirmationRow("Title", request.title)
                confirmationRow("Task ID", request.taskID)
            }
            Divider()
            Text("Task").font(.headline)
            ScrollView { Text(request.task).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(maxHeight: 160)
            HStack {
                Button("Back") { confirmation = nil }
                Spacer()
                Button("Launch One Managed Agent") {
                    confirmation = nil
                    actions.launch(request)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 560)
    }

    private func confirmationRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func review() {
        switch ManagedQuickLaunchRules.request(from: draft) {
        case .success(let request):
            issues = []
            confirmation = request
        case .failure(let failure):
            issues = failure.issues
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !draft.cwd.isEmpty { panel.directoryURL = URL(fileURLWithPath: draft.cwd) }
        if panel.runModal() == .OK, let url = panel.url {
            draft.cwd = url.standardizedFileURL.path
            issues.removeAll { $0.field == .cwd }
        }
    }

    private func loadPreset() {
        guard let preset = presets.first(where: { $0.id == selectedPresetID }) else { return }
        draft.apply(preset)
        issues = []
        presetError = nil
    }

    private func savePreset() {
        switch presetStore.save(name: presetName, draft: draft) {
        case .success(let updated):
            presets = updated
            selectedPresetID = presetName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            presetName = ""
            presetError = nil
        case .failure(let error):
            presetError = error.localizedDescription
        }
    }

    private func deletePreset() {
        presets = presetStore.delete(id: selectedPresetID)
        selectedPresetID = ""
        presetError = nil
    }
}
