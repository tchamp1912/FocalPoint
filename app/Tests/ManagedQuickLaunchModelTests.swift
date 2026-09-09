import Foundation

@main
enum ManagedQuickLaunchModelTests {
    static func main() throws {
        var draft = ManagedQuickLaunchDraft()
        draft.task = "Fix a one-line typo"
        draft.cwd = "/tmp"
        draft.agentType = "implementer"
        draft.provider = .codex
        draft.model = "gpt-5.6-sol"
        draft.title = "Fix typo"
        draft.taskID = "fix-typo-001"

        precondition(ManagedQuickLaunchRules.inferredComplexity(for: draft.task) == .simple)
        precondition(ManagedQuickLaunchRules.validate(draft, directoryExists: { $0 == "/tmp" }).isEmpty)
        precondition(ManagedQuickLaunchRules.recommendation(for: draft).model == "gpt-5.6-terra")

        draft.task = "Architect an end to end security migration across multiple modules"
        draft.provider = nil
        let complex = ManagedQuickLaunchRules.recommendation(for: draft)
        precondition(complex.complexity == .complex)
        precondition(complex.agentType == "planner")
        precondition(complex.provider == .claude)
        precondition(complex.model == "claude-opus-5")
        draft.provider = .codex
        draft.task = "Fix a one-line typo"

        guard case .success(let request) = ManagedQuickLaunchRules.request(
            from: draft, directoryExists: { $0 == "/tmp" }
        ) else { fatalError("valid draft should produce a typed request") }
        precondition(request.model == "gpt-5.6-sol")
        precondition(request.complexity == .simple)
        precondition(request.daemonPayload["model"] as? String == "gpt-5.6-sol")
        precondition(request.daemonPayload["agent_type"] as? String == "implementer")
        precondition(request.daemonPayload["role"] as? String == "worker")

        // Minimal form: task + project + selected agent/model, no title or task ID editing.
        var minimal = draft
        minimal.title = ""
        minimal.task = "  Fix login failures\n  and add coverage  "
        minimal.cwd = " /tmp \n"
        guard case .success(let minimalRequest) = ManagedQuickLaunchRules.request(
            from: minimal, directoryExists: { $0 == "/tmp" }
        ) else { fatalError("minimal form should derive its title and normalize the folder") }
        precondition(minimalRequest.title == "Fix login failures and add coverage")
        precondition(minimalRequest.cwd == "/tmp")
        precondition(minimalRequest.withLaunchIdentity(previous: minimalRequest).taskID == minimalRequest.taskID)
        let differentRequest = request.withLaunchIdentity(previous: minimalRequest)
        precondition(differentRequest.taskID != minimalRequest.taskID)
        precondition(request.withLaunchIdentity(previous: differentRequest).taskID == differentRequest.taskID)
        precondition(ManagedQuickLaunchRules.suggestedTitle(for: String(repeating: "a", count: 200)).count == 80)

        minimal.terminalColor = "#A78BFA"
        guard case .success(let specialized) = ManagedQuickLaunchRules.request(
            from: minimal, personaPrompt: "You review implementation correctness.", directoryExists: { $0 == "/tmp" }
        ) else { fatalError("agent instructions should be included") }
        precondition(specialized.task.contains("You review implementation correctness."))
        precondition(specialized.task.hasSuffix("Fix login failures\n  and add coverage"))
        precondition(specialized.title == minimalRequest.title)
        precondition(specialized.daemonPayload["terminal_color"] as? String == "#A78BFA")
        precondition(specialized.withLaunchIdentity(previous: minimalRequest).taskID != minimalRequest.taskID)
        minimal.task = " "
        if case .success = ManagedQuickLaunchRules.request(from: minimal, personaPrompt: "Instructions", directoryExists: { _ in true }) {
            fatalError("persona must not satisfy missing user task")
        }
        minimal.task = "Fix login"
        if case .success = ManagedQuickLaunchRules.request(from: minimal, personaPrompt: String(repeating: "x", count: 16_384), directoryExists: { _ in true }) {
            fatalError("combined prompt must respect daemon limit")
        }
        minimal.terminalColor = "red;run-shell"
        precondition(ManagedQuickLaunchRules.validate(minimal, directoryExists: { _ in true }).contains { $0.field == .terminalColor })

        var automatic = ManagedQuickLaunchDraft()
        automatic.task = "Implement a bounded repository fix"
        automatic.cwd = "/tmp"
        automatic.title = "Bounded fix"
        automatic.taskID = "bounded-fix-001"
        guard case .success(let automaticRequest) = ManagedQuickLaunchRules.request(
            from: automatic, directoryExists: { $0 == "/tmp" }
        ) else { fatalError("blank selections should resolve before launch") }
        precondition(automaticRequest.agentType == "implementer")
        precondition(automaticRequest.provider == .codex)
        precondition(automaticRequest.model == "gpt-5.6-terra")

        automatic.task = "Run tests and UI smoke verification in Xcode"
        guard case .success(let cursorRequest) = ManagedQuickLaunchRules.request(
            from: automatic, directoryExists: { $0 == "/tmp" }
        ) else { fatalError("verification task should resolve") }
        precondition(cursorRequest.provider == .cursor)
        precondition(cursorRequest.model == "composer-2.5")
        precondition(cursorRequest.agentType == "test-verifier")

        automatic.task = "Research and plan an architecture migration"
        guard case .success(let claudeRequest) = ManagedQuickLaunchRules.request(
            from: automatic, directoryExists: { $0 == "/tmp" }
        ) else { fatalError("planning task should resolve") }
        precondition(claudeRequest.provider == .claude)
        precondition(claudeRequest.model == "claude-opus-5")
        precondition(claudeRequest.agentType == "codebase-scout")

        // Explicit provider selection must survive task routing and review.
        for provider in ManagedQuickLaunchProvider.allCases {
            automatic.provider = provider
            let suggestion = ManagedQuickLaunchRules.recommendation(for: automatic)
            precondition(suggestion.provider == provider)
            guard case .success(let pinned) = ManagedQuickLaunchRules.request(
                from: automatic, directoryExists: { _ in true }
            ) else { fatalError("explicit provider with automatic model should resolve") }
            precondition(pinned.provider == provider)
            precondition(pinned.model == suggestion.model)
            precondition(pinned.daemonPayload["provider"] as? String == provider.rawValue)
        }
        automatic.provider = .claude
        automatic.task = "Implement a bounded repository fix"
        automatic.agentType = "implementer"
        guard case .success(let partial) = ManagedQuickLaunchRules.request(
            from: automatic, directoryExists: { _ in true }
        ) else { fatalError("explicit role with automatic model should resolve") }
        precondition(partial.model == "claude-sonnet-5")
        precondition(partial.provider == .claude)
        automatic.agentType = ""
        automatic.model = " claude-custom-model "
        guard case .success(let custom) = ManagedQuickLaunchRules.request(
            from: automatic, directoryExists: { _ in true }
        ) else { fatalError("custom model with automatic role should resolve") }
        precondition(custom.model == "claude-custom-model")
        precondition(custom.agentType == "implementer")
        automatic.model = "gpt-5.6-sol"
        guard case .failure(let mismatch) = ManagedQuickLaunchRules.request(
            from: automatic, directoryExists: { _ in true }
        ) else { fatalError("Claude must not launch a stale Codex model") }
        precondition(mismatch.issues.contains { $0.field == .model })

        draft.model = ""
        let missingModel = ManagedQuickLaunchRules.validate(draft, directoryExists: { _ in true })
        precondition(missingModel.contains { $0.field == .model }, "an explicit model is required")

        draft.model = "auto"
        let automaticModel = ManagedQuickLaunchRules.validate(draft, directoryExists: { _ in true })
        precondition(automaticModel.contains { $0.field == .model }, "automatic models must fail before launch")

        draft.model = "gpt-5.6-sol"
        draft.agentType = "default"
        let defaultAgent = ManagedQuickLaunchRules.validate(draft, directoryExists: { _ in true })
        precondition(defaultAgent.contains { $0.field == .agentType }, "default agent types must fail before launch")
        draft.agentType = "implementer"

        draft.taskID = "contains spaces"
        let badID = ManagedQuickLaunchRules.validate(draft, directoryExists: { _ in true })
        precondition(badID.contains { $0.field == .taskID })

        draft.taskID = "fix-typo-001"
        let suiteName = "ManagedQuickLaunchModelTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { fatalError("test defaults") }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ManagedQuickLaunchPresetStore(defaults: defaults)
        guard case .success(let saved) = store.save(name: "Daily", draft: draft) else {
            fatalError("valid preset should save")
        }
        precondition(saved.count == 1)
        var loaded = ManagedQuickLaunchDraft()
        loaded.task = "sensitive per-run text"
        loaded.taskID = "unique-run"
        loaded.apply(saved[0])
        precondition(loaded.task == "sensitive per-run text", "presets must not persist/replace tasks")
        precondition(loaded.taskID == "unique-run", "presets must not reuse task IDs")

        automatic.model = ""
        guard case .success(let automaticPresets) = store.save(name: "Claude coding", draft: automatic),
              let claudePreset = automaticPresets.first(where: { $0.name == "Claude coding" }) else {
            fatalError("automatic fields should resolve when saving a preset")
        }
        precondition(claudePreset.provider == .claude)
        precondition(claudePreset.model == "claude-sonnet-5")
        loaded.apply(claudePreset)
        precondition(loaded.provider == .claude)
        precondition(loaded.model == "claude-sonnet-5")

        let raw = defaults.data(forKey: ManagedQuickLaunchPresetStore.defaultsKey)!
        let persisted = String(decoding: raw, as: UTF8.self)
        precondition(!persisted.contains("sensitive per-run text"))
        precondition(!persisted.contains("unique-run"))

        var gatewayDraft = draft
        gatewayDraft.task = "Launch gateway task"
        gatewayDraft.title = "Gateway"
        gatewayDraft.cwd = "/tmp"
        gatewayDraft.taskID = "gateway-test"
        gatewayDraft.agentType = "implementer"
        gatewayDraft.provider = .claude
        gatewayDraft.customLauncher = "/tmp/otari launcher"
        gatewayDraft.model = "open/model-1"
        guard case .success(let customRequest) = ManagedQuickLaunchRules.request(
            from: gatewayDraft, directoryExists: { _ in true }, launcherExists: { $0 == "/tmp/otari launcher" }
        ) else { fatalError("Custom gateway model must be accepted") }
        precondition(customRequest.daemonPayload["custom_launcher"] as? String == gatewayDraft.customLauncher)
        var changedLauncher = customRequest
        changedLauncher.customLauncher = "/tmp/another-launcher"
        precondition(changedLauncher.withLaunchIdentity(previous: customRequest).taskID != customRequest.taskID)
        gatewayDraft.model = ""
        guard case .failure(let missingModel) = ManagedQuickLaunchRules.request(
            from: gatewayDraft, directoryExists: { _ in true }, launcherExists: { _ in true }
        ) else { fatalError("Custom launchers must not infer a Claude model") }
        precondition(missingModel.issues.contains { $0.field == .model })
        gatewayDraft.model = "gpt-6-astra"
        precondition(ManagedQuickLaunchRules.validate(gatewayDraft, directoryExists: { _ in true }, launcherExists: { _ in true }).allSatisfy { $0.field != .model })
        gatewayDraft.provider = .codex
        precondition(ManagedQuickLaunchRules.validate(gatewayDraft, directoryExists: { _ in true }, launcherExists: { _ in true }).contains { $0.field == .customLauncher })
        gatewayDraft.provider = .claude
        precondition(ManagedQuickLaunchRules.validate(gatewayDraft, directoryExists: { _ in true }, launcherExists: { _ in false }).contains { $0.field == .customLauncher })
        var gemini = ManagedQuickLaunchDraft(task: "Fix launch behavior", cwd: "/tmp", agentType: "implementer", provider: .gemini)
        guard case .success(let geminiRequest) = ManagedQuickLaunchRules.request(from: gemini, directoryExists: { _ in true }) else {
            fatalError("Gemini must launch with its own concrete suggestion")
        }
        precondition(geminiRequest.provider == .gemini)
        precondition(geminiRequest.model == "gemini-2.5-flash")
        precondition(geminiRequest.daemonPayload["provider"] as? String == "gemini")
        gemini.complexity = .complex
        precondition(ManagedQuickLaunchRules.recommendation(for: gemini).model == "gemini-2.5-pro")
        for foreignModel in ["gpt-6-astra", "claude-fable-5-1", "composer-2.5"] {
            gemini.model = foreignModel
            guard case .failure(let issue) = ManagedQuickLaunchRules.request(from: gemini, directoryExists: { _ in true }) else { fatalError("Provider mismatch accepted") }
            precondition(issue.issues.contains { $0.field == .model })
        }
        print("ManagedQuickLaunchModelTests: PASS")
    }
}
