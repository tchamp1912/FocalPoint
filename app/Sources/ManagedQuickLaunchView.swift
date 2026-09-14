// FocalPoint — a compact, catalog-backed launcher for one agent.
// MIT License.

import SwiftUI
import AppKit

struct ManagedQuickLaunchActions {
    var launch: (ManagedQuickLaunchRequest) async -> String?
    var cancel: () -> Void
}

struct ManagedQuickLaunchView: View {
    let recentProjects: [String]
    let isConnected: Bool
    let actions: ManagedQuickLaunchActions
    private let folderStore: ManagedProjectFolders
    @State private var pinnedFolders: [String]
    @State private var recentFolders: [String]
    @State private var folderError: String?

    @State private var draft: ManagedQuickLaunchDraft
    @State private var catalog: ManagedQuickLaunchCatalog
    @State private var issues: [ManagedQuickLaunchValidationIssue] = []
    @State private var launchError: String?
    @State private var isLaunching = false
    @State private var showOptions = false
    @State private var useCustomModel = false
    @AppStorage("managedQuickLaunch.customLauncherPath.v1") private var savedCustomLauncher = ""
    @State private var lastAttemptRequest: ManagedQuickLaunchRequest?
    @FocusState private var taskFocused: Bool

    init(initialCwd: String = "", recentProjects: [String] = [], isConnected: Bool = true,
         actions: ManagedQuickLaunchActions, catalog: ManagedQuickLaunchCatalog = .load(),
         folderStore: ManagedProjectFolders = .init()) {
        self.recentProjects = Array(Set(recentProjects.filter { !$0.isEmpty })).sorted()
        self.isConnected = isConnected
        self.actions = actions
        self.folderStore = folderStore
        _pinnedFolders = State(initialValue: folderStore.pinned)
        _recentFolders = State(initialValue: folderStore.recent)
        var initial = ManagedQuickLaunchDraft()
        initial.cwd = initialCwd.isEmpty ? folderStore.recent.first ?? folderStore.pinned.first ?? "" : initialCwd
        initial.provider = .codex
        initial.agentType = catalog.agents.first(where: { $0.id == "implementer" })?.id
            ?? catalog.agents.first?.id ?? ""
        _draft = State(initialValue: initial)
        _catalog = State(initialValue: catalog)
    }

    private var provider: ManagedQuickLaunchProvider { draft.provider ?? .codex }
    private var isCustomLauncher: Bool { provider == .claude && draft.customLauncher != nil }
    private var launcherName: String { isCustomLauncher ? "Custom Agent" : provider.displayName }
    private var suggestion: ManagedQuickLaunchRecommendation? {
        guard !isCustomLauncher else { return nil }
        return catalog.recommendation(provider: provider, agentType: draft.agentType,
                               complexity: ManagedQuickLaunchRules.effectiveComplexity(for: draft))
    }
    private var selectedModel: String { draft.model.isEmpty ? suggestion?.model ?? "" : draft.model }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    projectField
                    taskField
                    agentFields
                    DisclosureGroup("Options", isExpanded: $showOptions) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Session title (optional)", text: $draft.title)
                                .textFieldStyle(.roundedBorder)
                            Picker("Task size", selection: $draft.complexity) {
                                ForEach(ManagedQuickLaunchComplexity.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.menu)
                            terminalColorPicker
                            Text("The session title is taken from your task when left blank.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 10)
                    }
                    if !catalog.issues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(catalog.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            Button("Reload agent types and models") { reloadCatalog() }
                                .font(.caption)
                        }
                    }
                }
                .padding(24)
                .disabled(isLaunching)
            }
            Divider()
            footer
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 540)
        .onAppear { taskFocused = true }
        .onChange(of: draft) { _, _ in issues = []; launchError = nil }
        .onChange(of: draft.cwd) { _, _ in folderError = nil }
    }

    private var projectField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Project").font(.headline)
                Spacer()
                folderMenu
            }
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                TextField("Choose a project folder", text: $draft.cwd)
                    .textFieldStyle(.roundedBorder)
                Button { toggleFolderPin() } label: {
                    Image(systemName: currentFolderIsPinned ? "star.fill" : "star")
                        .foregroundStyle(currentFolderIsPinned ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(currentFolderIsPinned ? "Unpin this folder" : "Pin this folder for quick access")
                .accessibilityLabel(currentFolderIsPinned ? "Unpin folder" : "Pin folder")
                .disabled(draft.cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Browse…", action: chooseFolder)
            }
            if let folderError { Text(folderError).font(.caption).foregroundStyle(.red) }
        }
    }

    private var currentFolderIsPinned: Bool {
        ManagedProjectFolders.normalize(draft.cwd).map { pinnedFolders.contains($0) } ?? false
    }

    private var folderMenu: some View {
        let recent = recentFolders.filter { !pinnedFolders.contains($0) }
        let active = recentProjects.compactMap(ManagedProjectFolders.normalize)
            .filter { !pinnedFolders.contains($0) && !recent.contains($0) }
        return Menu {
            if !pinnedFolders.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedFolders, id: \.self) { path in
                        Button { selectFolder(path) } label: { Label(folderLabel(path), systemImage: "star.fill") }
                    }
                }
            }
            if !recent.isEmpty {
                Section("Recent") {
                    ForEach(recent, id: \.self) { path in Button(folderLabel(path)) { selectFolder(path) } }
                }
            }
            if !active.isEmpty {
                Section("From sessions") {
                    ForEach(Array(Set(active)).sorted(), id: \.self) { path in Button(folderLabel(path)) { selectFolder(path) } }
                }
            }
            if pinnedFolders.isEmpty && recent.isEmpty && active.isEmpty { Text("No saved folders yet") }
            Divider()
            Button("Choose Folder…", action: chooseFolder)
            if !recentFolders.isEmpty {
                Button("Clear Recent Folders") { folderStore.clearRecent(); synchronizeFolders() }
            }
        } label: { Label("Saved folders", systemImage: "folder.badge.gearshape") }
        .menuStyle(.borderlessButton).fixedSize().font(.callout)
    }

    private func folderLabel(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func synchronizeFolders() {
        pinnedFolders = folderStore.pinned
        recentFolders = folderStore.recent
    }

    private func selectFolder(_ path: String) {
        draft.cwd = path
        _ = folderStore.remember(path)
        synchronizeFolders()
    }

    private func toggleFolderPin() {
        if !folderStore.togglePin(draft.cwd) {
            folderError = "Choose an existing folder. If your pinned list is full, unpin a folder first."
        } else { folderError = nil }
        synchronizeFolders()
    }

    private var taskField: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("What should the agent do?").font(.headline)
            TextEditor(text: $draft.task)
                .font(.body)
                .focused($taskFocused)
                .scrollContentBackground(.hidden)
                .padding(7)
                .frame(height: 125)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .overlay(alignment: .topLeading) {
                    if draft.task.isEmpty {
                        Text("Describe the work you want done…")
                            .foregroundStyle(.tertiary).padding(12).allowsHitTesting(false)
                    }
                }
                .accessibilityLabel("Task")
        }
    }

    private var agentFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: Binding(
                get: { provider },
                set: {
                    rememberCustomLauncher()
                    draft.provider = $0
                    if $0 != .claude { draft.customLauncher = nil }
                    resetModel()
                }
            )) {
                ForEach(ManagedQuickLaunchProvider.allCases) { Text($0.displayName).tag($0) }
            }.pickerStyle(.segmented)

            if provider == .claude { customLauncherFields }

            Picker("Agent type", selection: Binding(
                get: { draft.agentType },
                set: { agentType in
                    // Keep the currently shown model, including a suggestion,
                    // when changing the persona. Custom input stays untouched.
                    if draft.model.isEmpty && !useCustomModel && !isCustomLauncher {
                        draft.model = selectedModel
                    }
                    draft.agentType = agentType
                }
            )) {
                if catalog.agents.isEmpty { Text("No agent types installed").tag("") }
                ForEach(catalog.agents) { Text($0.displayName).tag($0.id) }
            }
            .pickerStyle(.menu)
            .disabled(catalog.agents.isEmpty)

            if let agent = catalog.agents.first(where: { $0.id == draft.agentType }) {
                Text(agent.description).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isCustomLauncher {
                TextField("Gateway model ID", text: $draft.model)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Gateway model ID")
                Text("Enter the model ID accepted by your launcher.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Model", selection: Binding(
                    get: { useCustomModel ? "__custom__" : draft.model },
                    set: { value in
                        useCustomModel = value == "__custom__"
                        draft.model = useCustomModel ? "" : value
                    }
                )) {
                    Text(suggestion.map { "Suggested · \($0.model)" } ?? "Choose a model") .tag("")
                    ForEach(catalog.models(provider: provider), id: \.self) {
                        Text($0).tag($0)
                    }
                    Divider()
                    Text("Custom model…").tag("__custom__")
                }
                .pickerStyle(.menu)
                if useCustomModel {
                    TextField("Model ID", text: $draft.model).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Custom model ID")
                }
            }
        }
    }

    private var customLauncherFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Launcher", selection: Binding(
                get: { isCustomLauncher },
                set: { custom in
                    rememberCustomLauncher()
                    draft.customLauncher = custom ? savedCustomLauncher : nil
                    resetModel()
                }
            )) {
                Text("Claude Code").tag(false)
                Text("Custom script").tag(true)
            }.pickerStyle(.menu)
            if isCustomLauncher {
                HStack {
                    TextField("/absolute/path/to/launcher", text: Binding(
                        get: { draft.customLauncher ?? "" },
                        set: { draft.customLauncher = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Custom launcher script path")
                    .onSubmit { rememberCustomLauncher() }
                    Button("Browse…", action: chooseCustomLauncher)
                }
                Text("Choose an executable script that accepts Claude's model, prompt, and resume arguments.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rememberCustomLauncher() {
        guard let rawPath = draft.customLauncher,
              let path = ManagedProjectFolders.normalize(rawPath) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) else { return }
        draft.customLauncher = path
        savedCustomLauncher = path
    }

    private func chooseCustomLauncher() {
        let panel = NSOpenPanel()
        panel.title = "Choose Custom Launcher"
        panel.prompt = "Choose Launcher"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let path = draft.customLauncher.flatMap(ManagedProjectFolders.normalize) {
            panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            draft.customLauncher = url.standardizedFileURL.path
            rememberCustomLauncher()
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isConnected {
                Label("FocalPoint is offline. Reconnect the daemon to launch an agent.", systemImage: "bolt.slash")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(issues) { Text($0.message).font(.callout).foregroundStyle(.red) }
            if let launchError { Text(launchError).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack(spacing: 10) {
                Button("Cancel", action: actions.cancel).disabled(isLaunching)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isLaunching {
                    ProgressView().controlSize(.small)
                    Text("Opening \(launcherName)…").font(.callout).foregroundStyle(.secondary)
                }
                Button("Launch \(launcherName)") { launch() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isLaunching || !isConnected || catalog.agents.isEmpty)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(.bar)
    }

    private func resetModel() {
        if isCustomLauncher {
            draft.model = ""
            useCustomModel = true
            return
        }
        draft.model = suggestion == nil ? catalog.models(provider: provider).first ?? "" : ""
        useCustomModel = false
    }

    private var terminalColorPicker: some View {
        HStack(spacing: 10) {
            Text("Terminal color")
            Spacer()
            ForEach(["", "#60A5FA", "#A78BFA", "#34D399", "#FBBF24", "#FB7185", "#22D3EE"], id: \.self) { hex in
                Button {
                    draft.terminalColor = hex.isEmpty ? nil : hex
                } label: {
                    ZStack {
                        Circle().fill(accentColor(hex)).frame(width: 23, height: 23)
                        if (draft.terminalColor ?? "") == hex {
                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(colorName(hex))
                .accessibilityAddTraits((draft.terminalColor ?? "") == hex ? [.isSelected] : [])
                .help(colorName(hex))
            }
        }
    }

    private func colorName(_ hex: String) -> String {
        ["": "Default", "#60A5FA": "Blue", "#A78BFA": "Purple", "#34D399": "Green",
         "#FBBF24": "Amber", "#FB7185": "Rose", "#22D3EE": "Cyan"][hex] ?? hex
    }

    private func accentColor(_ hex: String) -> Color {
        guard let rgb = UInt32(hex.dropFirst(), radix: 16) else { return .gray }
        return Color(red: Double((rgb >> 16) & 255) / 255,
                     green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }

    private func reloadCatalog() {
        let previousModel = selectedModel
        catalog = .load()
        if !catalog.agents.contains(where: { $0.id == draft.agentType }) {
            draft.agentType = catalog.agents.first?.id ?? ""
        }
        if !isCustomLauncher && !useCustomModel {
            draft.model = catalog.models(provider: provider).contains(previousModel) ? previousModel : ""
        }
    }

    private func launch() {
        guard !isLaunching, isConnected else { return }
        rememberCustomLauncher()
        var resolved = draft
        resolved.model = isCustomLauncher || useCustomModel ? draft.model : selectedModel
        guard !resolved.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues = [.init(field: .model, message: isCustomLauncher ? "Enter the model ID accepted by your launcher." : "Choose a model or enter a custom model ID.")]
            return
        }
        guard let agent = catalog.agents.first(where: { $0.id == draft.agentType }) else {
            issues = [.init(field: .agentType, message: "Choose an installed agent type.")]
            return
        }
        guard !draft.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues = [.init(field: .task, message: "Describe what the agent should do.")]
            taskFocused = true
            return
        }
        if resolved.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.title = ManagedQuickLaunchRules.suggestedTitle(for: draft.task)
        }
        switch ManagedQuickLaunchRules.request(from: resolved, personaPrompt: agent.personaPrompt) {
        case .failure(let failure): issues = failure.issues
        case .success(let validated):
            let request = validated.withLaunchIdentity(previous: lastAttemptRequest)
            lastAttemptRequest = request
            issues = []
            launchError = nil
            isLaunching = true
            Task { @MainActor in
                let failure = await actions.launch(request)
                isLaunching = false
                if let failure { launchError = failure }
                else {
                    _ = folderStore.remember(request.cwd)
                    synchronizeFolders()
                    actions.cancel()
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Project Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if !draft.cwd.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (draft.cwd as NSString).expandingTildeInPath)
        }
        if panel.runModal() == .OK, let url = panel.url { selectFolder(url.standardizedFileURL.path) }
    }
}
