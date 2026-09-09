// FocalPoint menu-bar app — pure domain model for launching one managed agent.
// MIT License.

import Foundation

enum ManagedQuickLaunchProvider: String, CaseIterable, Codable, Identifiable {
    case codex, claude, cursor

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum ManagedQuickLaunchComplexity: String, CaseIterable, Codable, Identifiable {
    case infer, simple, standard, complex

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .infer: return "Infer from task"
        case .simple: return "Simple"
        case .standard: return "Standard"
        case .complex: return "Complex"
        }
    }
}

/// The complete, typed hand-off to whichever app integration owns the daemon.
/// Every launch-critical choice is present; in particular `model` can never be
/// omitted and therefore cannot fall back to a previous UI selection.
struct ManagedQuickLaunchRequest: Equatable, Identifiable {
    let task: String
    let cwd: String
    let agentType: String
    let provider: ManagedQuickLaunchProvider
    let model: String
    let title: String
    let taskID: String
    let complexity: ManagedQuickLaunchComplexity
    var terminalColor: String? = nil
    var customLauncher: String? = nil
    var id: String { taskID }

    /// An unchanged retry reuses the daemon's receipt; edited work gets a new id.
    func withLaunchIdentity(previous: Self?) -> Self {
        guard let previous else { return self }
        func identified(_ id: String) -> Self {
            .init(task: task, cwd: cwd, agentType: agentType, provider: provider,
                  model: model, title: title, taskID: id, complexity: complexity, terminalColor: terminalColor, customLauncher: customLauncher)
        }
        let retry = identified(previous.taskID)
        return retry == previous ? retry : identified(ManagedQuickLaunchRules.mintTaskID(prefix: "task"))
    }

    var daemonPayload: [String: Any] {
        var payload: [String: Any] = [
            "cmd": "launch-session",
            "provider": provider.rawValue,
            "model": model,
            "agent_type": agentType,
            "cwd": cwd,
            "task": task,
            "task_id": taskID,
            "title": title,
            "role": "worker",
        ]
        if let terminalColor { payload["terminal_color"] = terminalColor }
        if let customLauncher { payload["custom_launcher"] = customLauncher }
        return payload
    }
}

struct ManagedQuickLaunchDraft: Equatable {
    var task = ""
    var cwd = ""
    var agentType = "" // Blank fields resolve independently from this task.
    var provider: ManagedQuickLaunchProvider? = nil // nil is explicitly Automatic.
    var model = "" // Intentionally blank: there is no remembered/implicit model.
    var title = ""
    var taskID = ManagedQuickLaunchRules.mintTaskID(prefix: "task")
    var complexity: ManagedQuickLaunchComplexity = .infer
    var terminalColor: String? = nil
    var customLauncher: String? = nil

    mutating func apply(_ preset: ManagedQuickLaunchPreset) {
        cwd = preset.cwd
        agentType = preset.agentType
        provider = preset.provider
        model = preset.model
        title = preset.title
        complexity = preset.complexity
        // Task text and task ID are deliberately per-launch and never loaded
        // from UserDefaults. They can contain secrets or identify an old run.
    }
}

struct ManagedQuickLaunchValidationIssue: Equatable, Identifiable {
    enum Field: String { case task, cwd, agentType, provider, model, title, taskID, terminalColor, customLauncher }
    let field: Field
    let message: String
    var id: String { field.rawValue }
}

struct ManagedQuickLaunchValidationFailure: Error, Equatable {
    let issues: [ManagedQuickLaunchValidationIssue]
}

struct ManagedQuickLaunchRecommendation: Equatable {
    let complexity: ManagedQuickLaunchComplexity
    let agentType: String
    let provider: ManagedQuickLaunchProvider
    let model: String
    let rationale: String
}

enum ManagedQuickLaunchRules {
    private enum TaskIntent {
        case planning
        case threatModeling
        case research
        case synthesis
        case verification
        case performance
        case correctnessReview
        case implementation
    }

    static func inferredComplexity(for task: String) -> ManagedQuickLaunchComplexity {
        let normalized = task.lowercased()
        let complexSignals = ["architect", "migration", "security", "concurrency", "distributed",
                              "end to end", "multiple modules", "production incident"]
        let simpleSignals = ["rename", "typo", "copy change", "one-line", "single line"]
        if task.utf8.count > 900 || complexSignals.contains(where: normalized.contains) {
            return .complex
        }
        if task.utf8.count < 180 && simpleSignals.contains(where: normalized.contains) {
            return .simple
        }
        return .standard
    }

    static func effectiveComplexity(for draft: ManagedQuickLaunchDraft) -> ManagedQuickLaunchComplexity {
        draft.complexity == .infer ? inferredComplexity(for: draft.task) : draft.complexity
    }

    /// Suggestions honor an explicit provider; only Automatic routes by task.
    static func recommendation(for draft: ManagedQuickLaunchDraft) -> ManagedQuickLaunchRecommendation {
        let suggested = taskRecommendation(for: draft)
        guard let provider = draft.provider else { return suggested }
        let model: String
        switch provider {
        case .codex: model = suggested.complexity == .complex ? "gpt-5.6-sol" : "gpt-5.6-terra"
        case .claude:
            switch suggested.complexity {
            case .simple: model = "claude-haiku-4-5"
            case .complex: model = "claude-opus-5"
            case .standard, .infer: model = "claude-sonnet-5"
            }
        case .cursor: model = "composer-2.5"
        }
        return .init(complexity: suggested.complexity, agentType: suggested.agentType,
                     provider: provider, model: model,
                     rationale: "Suggested for this task's complexity using your selected provider.")
    }

    static func suggestedModels(for provider: ManagedQuickLaunchProvider) -> [String] {
        switch provider {
        case .codex: return ["gpt-5.6-terra", "gpt-5.6-sol"]
        case .claude: return ["claude-haiku-4-5", "claude-sonnet-5", "claude-opus-5"]
        case .cursor: return ["composer-2.5"]
        }
    }

    private static func taskRecommendation(for draft: ManagedQuickLaunchDraft) -> ManagedQuickLaunchRecommendation {
        let complexity = effectiveComplexity(for: draft)
        let intent = taskIntent(for: draft.task)

        switch intent {
        case .verification:
            return .init(complexity: complexity, agentType: "test-verifier", provider: .cursor,
                         model: "composer-2.5",
                         rationale: "IDE-grounded test, build, and UI verification is routed to Cursor Composer.")
        case .planning, .threatModeling, .research, .synthesis:
            let agentType: String
            switch intent {
            case .planning: agentType = "planner"
            case .threatModeling: agentType = "threat-modeler"
            case .research: agentType = "codebase-scout"
            case .synthesis: agentType = "synthesizer"
            default: preconditionFailure("unreachable task intent")
            }
            let model: String
            switch complexity {
            case .simple: model = "claude-haiku-4-5"
            case .standard, .infer: model = "claude-sonnet-5"
            case .complex: model = "claude-opus-5"
            }
            return .init(complexity: complexity, agentType: agentType, provider: .claude,
                         model: model,
                         rationale: "Planning, research, threat modeling, and synthesis use a task-matched Claude tier.")
        case .implementation, .performance, .correctnessReview:
            let agentType: String
            switch intent {
            case .performance: agentType = "perf-reviewer"
            case .correctnessReview: agentType = "correctness-reviewer"
            default: agentType = "implementer"
            }
            let model = complexity == .complex ? "gpt-5.6-sol" : "gpt-5.6-terra"
            return .init(complexity: complexity, agentType: agentType, provider: .codex,
                         model: model,
                         rationale: complexity == .complex
                            ? "Complex repository work uses Sol; ordinary implementation and review stay on the more efficient Terra tier."
                            : "Ordinary repository implementation and review use the efficient Terra tier.")
        }
    }

    static func validate(
        _ draft: ManagedQuickLaunchDraft,
        directoryExists: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        },
        launcherExists: (String) -> Bool = isExecutableLauncher
    ) -> [ManagedQuickLaunchValidationIssue] {
        var issues: [ManagedQuickLaunchValidationIssue] = []
        let task = draft.task.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.isEmpty || draft.task.utf8.count > 16_384 || draft.task.contains("\0") {
            issues.append(.init(field: .task, message: "Task must contain 1–16,384 UTF-8 bytes and no null characters."))
        }
        if !draft.cwd.hasPrefix("/") || !directoryExists(draft.cwd) {
            issues.append(.init(field: .cwd, message: "Choose an existing absolute project folder."))
        }
        let agentType = draft.agentType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !matches(agentType, pattern: #"[a-z0-9][a-z0-9-]{0,63}"#)
            || forbiddenAgentType(agentType) {
            issues.append(.init(field: .agentType, message: "Choose a concrete agent type; auto, default, and general are not launchable."))
        }
        if draft.provider == nil {
            issues.append(.init(field: .provider, message: "Choose a provider before saving these settings."))
        }
        if let launcher = draft.customLauncher {
            if draft.provider != .claude {
                issues.append(.init(field: .customLauncher, message: "Custom launchers use the Claude session integration."))
            } else if !launcher.hasPrefix("/") || launcher.contains("\0") || !launcherExists(launcher) {
                issues.append(.init(field: .customLauncher, message: "Choose an executable launcher script using its full path."))
            }
        }
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if (draft.provider == .claude && draft.customLauncher == nil && (model.hasPrefix("gpt-") || model.hasPrefix("composer-")))
            || (draft.provider == .codex && (model.hasPrefix("claude-") || model.hasPrefix("composer-"))) {
            issues.append(.init(field: .model, message: "This model belongs to another provider. Choose a model for the selected provider."))
        } else if !matches(model, pattern: #"[A-Za-z0-9][A-Za-z0-9._/@:-]{0,127}"#)
            || forbiddenModel(model) {
            issues.append(.init(field: .model, message: "Enter a concrete model ID; auto and provider defaults are not launchable."))
        }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title.count > 120 || title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            issues.append(.init(field: .title, message: "Title must contain 1–120 printable characters."))
        }
        if !matches(draft.taskID, pattern: #"[A-Za-z0-9][A-Za-z0-9._-]{0,63}"#) {
            issues.append(.init(field: .taskID, message: "Task ID must be 1–64 letters, numbers, dots, underscores, or dashes."))
        }
        if let color = draft.terminalColor, !matches(color, pattern: "#[0-9A-Fa-f]{6}") {
            issues.append(.init(field: .terminalColor, message: "Choose a valid terminal color."))
        }
        return issues
    }

    static func request(from draft: ManagedQuickLaunchDraft,
                        personaPrompt: String? = nil,
                        directoryExists: (String) -> Bool = { path in
                            var isDirectory: ObjCBool = false
                            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                                && isDirectory.boolValue
                        },
                        launcherExists: (String) -> Bool = isExecutableLauncher) -> Result<ManagedQuickLaunchRequest, ManagedQuickLaunchValidationFailure> {
        var resolved = draft
        resolved.cwd = (draft.cwd.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        if let launcher = draft.customLauncher {
            resolved.customLauncher = (launcher.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        }
        if draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.title = suggestedTitle(for: draft.task)
        }
        let hasAgentType = !draft.agentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasModel = !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let selection = recommendation(for: draft)
        if !hasAgentType { resolved.agentType = selection.agentType }
        if !hasModel && draft.customLauncher == nil { resolved.model = selection.model }
        resolved.provider = draft.provider ?? selection.provider
        resolved.agentType = resolved.agentType.trimmingCharacters(in: .whitespacesAndNewlines)
        resolved.model = resolved.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let issues = validate(resolved, directoryExists: directoryExists, launcherExists: launcherExists)
        guard issues.isEmpty else { return .failure(.init(issues: issues)) }
        let userTask = resolved.task.trimmingCharacters(in: .whitespacesAndNewlines)
        let launchTask = personaPrompt.map { "Agent instructions:\n\($0)\n\nTask:\n\(userTask)" } ?? userTask
        guard launchTask.utf8.count <= 16_384, !launchTask.contains("\0") else {
            return .failure(.init(issues: [.init(field: .task,
                message: "The task and agent instructions are too long. Shorten the task or choose another agent type.")]))
        }
        return .success(.init(
            task: launchTask,
            cwd: URL(fileURLWithPath: resolved.cwd).standardizedFileURL.path,
            agentType: resolved.agentType,
            provider: resolved.provider ?? selection.provider,
            model: resolved.model,
            title: resolved.title.trimmingCharacters(in: .whitespacesAndNewlines),
            taskID: resolved.taskID,
            complexity: effectiveComplexity(for: resolved),
            terminalColor: resolved.terminalColor,
            customLauncher: resolved.customLauncher
        ))
    }

    static func isExecutableLauncher(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    static func suggestedTitle(for task: String) -> String {
        let words = task.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        return String(words.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined().prefix(80))
    }

    static func mintTaskID(prefix: String) -> String {
        let safe = prefix.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let stem = String(String(safe).prefix(36)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(stem.isEmpty ? "task" : stem)-\(UUID().uuidString.lowercased())".prefix(64).description
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil
    }

    private static func forbiddenAgentType(_ value: String) -> Bool {
        switch value.lowercased() {
        case "auto", "default", "general": return true
        default: return false
        }
    }

    private static func forbiddenModel(_ value: String) -> Bool {
        switch value.lowercased() {
        case "auto", "default", "provider-default": return true
        default: return false
        }
    }

    private static func taskIntent(for task: String) -> TaskIntent {
        let normalized = task.lowercased()
        func containsAny(_ signals: [String]) -> Bool {
            signals.contains(where: normalized.contains)
        }
        if containsAny(["test verification", "verify tests", "run tests", "ui smoke", "xcode",
                        "ide-grounded", "build verification", "reproduce in cursor"]) {
            return .verification
        }
        if containsAny(["threat model", "abuse case", "attack surface"]) { return .threatModeling }
        if containsAny(["research", "investigate options", "survey", "codebase scout"]) { return .research }
        if containsAny(["synthesize", "synthesis", "reconcile findings"]) { return .synthesis }
        if containsAny(["plan ", "planning", "architect", "architecture", "design proposal",
                        "migration strategy"]) { return .planning }
        if containsAny(["latency", "performance", "benchmark", "profil", "optimiz"]) { return .performance }
        if containsAny(["correctness review", "review correctness", "code review", "audit implementation"]) {
            return .correctnessReview
        }
        return .implementation
    }
}

// MARK: - Presets

/// A reusable configuration, intentionally excluding task text and task ID.
/// No credentials, environment variables, prompts, or daemon responses are
/// accepted by this schema, so its UserDefaults representation cannot grow
/// into a secret store accidentally.
struct ManagedQuickLaunchPreset: Codable, Equatable, Identifiable {
    var name: String
    var cwd: String
    var agentType: String
    var provider: ManagedQuickLaunchProvider
    var model: String
    var title: String
    var complexity: ManagedQuickLaunchComplexity
    var id: String { name.lowercased() }

    init(name: String, draft: ManagedQuickLaunchDraft) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        cwd = draft.cwd
        agentType = draft.agentType
        provider = draft.provider ?? ManagedQuickLaunchRules.recommendation(for: draft).provider
        model = draft.model
        title = draft.title
        complexity = draft.complexity
    }
}

enum ManagedQuickLaunchPresetError: Error, Equatable, LocalizedError {
    case invalidName
    case invalidPreset(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Preset name must contain 1–60 printable characters."
        case .invalidPreset(let reason): return reason
        case .encodingFailed: return "The preset could not be encoded safely."
        }
    }
}

final class ManagedQuickLaunchPresetStore {
    static let defaultsKey = "managedQuickLaunch.presets.v1"
    private let defaults: UserDefaults
    private(set) var presets: [ManagedQuickLaunchPreset]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey), data.count <= 256_000,
           let decoded = try? JSONDecoder().decode([ManagedQuickLaunchPreset].self, from: data) {
            // An unavailable external/network folder must not silently erase
            // a preset. Structural safety is checked here; existence is
            // revalidated both when saving and immediately before launch.
            presets = Array(decoded.prefix(50)).filter { Self.isSafe($0, requireExistingDirectory: false) }
        } else {
            presets = []
        }
    }

    func save(name: String, draft: ManagedQuickLaunchDraft) -> Result<[ManagedQuickLaunchPreset], ManagedQuickLaunchPresetError> {
        var resolved = draft
        let selection = ManagedQuickLaunchRules.recommendation(for: draft)
        resolved.provider = draft.provider ?? selection.provider
        if draft.agentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.agentType = selection.agentType
        }
        if draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved.model = selection.model
        }
        let preset = ManagedQuickLaunchPreset(name: name, draft: resolved)
        guard !preset.name.isEmpty, preset.name.count <= 60,
              !preset.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return .failure(.invalidName)
        }
        guard Self.isSafe(preset, requireExistingDirectory: true) else {
            return .failure(.invalidPreset("Complete the folder, agent type, explicit model, and title before saving."))
        }
        var updated = presets.filter { $0.id != preset.id }
        updated.append(preset)
        updated.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard updated.count <= 50, let data = try? JSONEncoder().encode(updated), data.count <= 256_000 else {
            return .failure(.encodingFailed)
        }
        defaults.set(data, forKey: Self.defaultsKey)
        presets = updated
        return .success(updated)
    }

    func delete(id: String) -> [ManagedQuickLaunchPreset] {
        presets.removeAll { $0.id == id }
        if presets.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.defaultsKey) }
        return presets
    }

    private static func isSafe(_ preset: ManagedQuickLaunchPreset,
                               requireExistingDirectory: Bool) -> Bool {
        let draft = ManagedQuickLaunchDraft(task: "placeholder", cwd: preset.cwd,
                                            agentType: preset.agentType, provider: preset.provider,
                                            model: preset.model, title: preset.title,
                                            taskID: "placeholder", complexity: preset.complexity)
        return ManagedQuickLaunchRules.validate(draft, directoryExists: { path in
            if requireExistingDirectory {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            return path.hasPrefix("/") && path.utf8.count <= 4_096
        }).isEmpty
    }
}
