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
        let complex = ManagedQuickLaunchRules.recommendation(for: draft)
        precondition(complex.complexity == .complex)
        precondition(complex.agentType == "planner")
        precondition(complex.provider == .claude)
        precondition(complex.model == "claude-opus-5")
        draft.task = "Fix a one-line typo"

        guard case .success(let request) = ManagedQuickLaunchRules.request(
            from: draft, directoryExists: { $0 == "/tmp" }
        ) else { fatalError("valid draft should produce a typed request") }
        precondition(request.model == "gpt-5.6-sol")
        precondition(request.complexity == .simple)
        precondition(request.daemonPayload["model"] as? String == "gpt-5.6-sol")
        precondition(request.daemonPayload["agent_type"] as? String == "implementer")
        precondition(request.daemonPayload["role"] as? String == "worker")

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

        let raw = defaults.data(forKey: ManagedQuickLaunchPresetStore.defaultsKey)!
        let persisted = String(decoding: raw, as: UTF8.self)
        precondition(!persisted.contains("sensitive per-run text"))
        precondition(!persisted.contains("unique-run"))

        print("ManagedQuickLaunchModelTests: PASS")
    }
}
