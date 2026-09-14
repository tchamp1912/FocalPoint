import Foundation

@main
enum ManagedQuickLaunchCatalogTests {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("quick-launch-catalog-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let packages = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("packages")
        let bundledCatalog = packages.appendingPathComponent("model-catalog.toml")
        let root = temporary.appendingPathComponent("config")
        let agents = root.appendingPathComponent("agents")
        try fm.createDirectory(at: agents, withIntermediateDirectories: true)
        for name in ["implementer", "planner"] {
            try fm.copyItem(at: packages.appendingPathComponent("agents/\(name)"),
                            to: agents.appendingPathComponent(name))
        }
        let valid = ManagedQuickLaunchCatalog.load(configRoot: root, bundledCatalogURL: bundledCatalog)
        precondition(valid.issues.isEmpty, "valid installed catalog: \(valid.issues)")
        precondition(Set(valid.agents.map(\.id)) == ["implementer", "planner"], "bundled but uninstalled types must not appear")
        let implementation = valid.agents.first { $0.id == "implementer" }!
        precondition(implementation.displayName == "Implementation")
        precondition(!implementation.description.isEmpty)
        precondition(!implementation.personaPrompt.isEmpty)
        precondition(!implementation.preferredProviders.isEmpty)
        for provider in [ManagedQuickLaunchProvider.claude, .codex, .gemini] {
            let recommendation = valid.recommendation(provider: provider, agentType: "implementer", complexity: .standard)
            precondition(recommendation?.provider == provider)
            precondition(valid.models(provider: provider).contains(recommendation!.model))
        }
        precondition(valid.models(provider: .cursor) == ["composer-2.5"], "provider model choices must not require an unrelated role to be installed")
        precondition(valid.recommendation(provider: .cursor, agentType: "implementer", complexity: .standard) == nil)
        precondition(valid.recommendation(provider: .codex, agentType: "not-installed", complexity: .standard) == nil)
        precondition(valid.recommendation(provider: nil, agentType: "planner", complexity: .complex)?.provider == .claude)

        precondition(valid.models(provider: .gemini).contains("gemini-3.1-pro-preview"))
        precondition(!valid.models(provider: .codex).contains("gemini-2.5-flash"))
        precondition(valid.recommendation(provider: .gemini, agentType: "planner", complexity: .complex)?.model == "gemini-2.5-pro")
        precondition(valid.models(provider: .codex).contains("gpt-6-astra"))
        precondition(!valid.models(provider: .claude).contains("gpt-6-astra"))
        precondition(valid.models(provider: .claude).contains("claude-fable-5-1"))
        precondition(!valid.models(provider: .codex).contains("claude-fable-5-1"))
        precondition(valid.recommendation(provider: .codex, agentType: "implementer", complexity: .standard)?.model == "gpt-5.6-terra",
                     "additional choices must not change recommendations")

        let override = """
        [catalog]
        version = 1
        [[selection]]
        provider = "claude"
        complexity = "substantial"
        agent_type = "implementer"
        model = "claude-custom-tier"
        [[resolution]]
        complexity = "substantial"
        agent_type = "implementer"
        provider = "claude"
        """
        let overrideURL = root.appendingPathComponent("model-catalog.toml")
        try override.write(to: overrideURL, atomically: true, encoding: .utf8)
        let overlaid = ManagedQuickLaunchCatalog.load(configRoot: root, bundledCatalogURL: bundledCatalog)
        precondition(overlaid.issues.isEmpty)
        precondition(overlaid.recommendation(provider: .claude, agentType: "implementer", complexity: .standard)?.model == "claude-custom-tier")
        precondition(overlaid.recommendation(provider: nil, agentType: "implementer", complexity: .standard)?.model == "claude-custom-tier")
        precondition(overlaid.models(provider: .claude).contains("claude-custom-tier"))
        precondition(overlaid.models(provider: .claude).contains("claude-fable-5-1"),
                     "existing user overrides must retain additional bundled choices")
        let duplicateChoice = override + "\n[[model]]\nprovider = \"codex\"\nmodel = \"gpt-6-astra\"\n[[model]]\nprovider = \"codex\"\nmodel = \"gpt-6-astra\"\n"
        try duplicateChoice.write(to: overrideURL, atomically: true, encoding: .utf8)
        precondition(!ManagedQuickLaunchCatalog.load(configRoot: root, bundledCatalogURL: bundledCatalog).issues.isEmpty)
        try "broken toml".write(to: overrideURL, atomically: true, encoding: .utf8)
        let brokenOverlay = ManagedQuickLaunchCatalog.load(configRoot: root, bundledCatalogURL: bundledCatalog)
        precondition(!brokenOverlay.issues.isEmpty)
        precondition(brokenOverlay.models(provider: .codex).isEmpty,
                     "broken override must not silently fall back to bundled models")
        precondition(brokenOverlay.recommendation(provider: .claude, agentType: "implementer", complexity: .complex) == nil)
        try fm.removeItem(at: overrideURL)

        let manifest = try String(contentsOf: agents.appendingPathComponent("implementer/type.toml"), encoding: .utf8)
        let malformedCases: [(String, String)] = [
            ("bad-provider", manifest.replacingOccurrences(of: "implementer", with: "bad-provider").replacingOccurrences(of: "prefer = [\"claude\"]", with: "prefer = [\"unknown\"]")),
            ("wrong-name", manifest),
            ("bad-path", manifest.replacingOccurrences(of: "implementer", with: "bad-path").replacingOccurrences(of: "prompt = \"persona.md\"", with: "prompt = \"../secret.md\"")),
            ("bad-constraint", manifest.replacingOccurrences(of: "implementer", with: "bad-constraint") + "\n[enforced]\nread_only = false\n"),
            ("broken", "broken toml")
        ]
        for (name, contents) in malformedCases {
            let directory = agents.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: directory.appendingPathComponent("type.toml"), atomically: true, encoding: .utf8)
        }
        let filtered = ManagedQuickLaunchCatalog.load(configRoot: root, bundledCatalogURL: bundledCatalog)
        precondition(filtered.agents == valid.agents)
        precondition(filtered.issues.count == malformedCases.count)

        // Prompt contents must be readable, bounded, and stay within the package.
        for name in ["missing-prompt", "large-prompt", "bad-utf8", "external-link", "constrained"] {
            let directory = agents.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var contents = manifest.replacingOccurrences(of: "implementer", with: name)
            if name == "constrained" { contents += "\n[enforced]\nread_only = true\n" }
            try contents.write(to: directory.appendingPathComponent("type.toml"), atomically: true, encoding: .utf8)
            let promptURL = directory.appendingPathComponent("persona.md")
            switch name {
            case "large-prompt": try Data(repeating: 65, count: 16_385).write(to: promptURL)
            case "bad-utf8": try Data([0xFF]).write(to: promptURL)
            case "external-link":
                let outside = temporary.appendingPathComponent("outside.md")
                try "Outside persona".write(to: outside, atomically: true, encoding: .utf8)
                try fm.createSymbolicLink(at: promptURL, withDestinationURL: outside)
            case "constrained": try "Read only".write(to: promptURL, atomically: true, encoding: .utf8)
            default: break
            }
        }
        let unsafe = ManagedQuickLaunchCatalog.load(configRoot: root, bundledCatalogURL: bundledCatalog)
        precondition(unsafe.agents == valid.agents)
        precondition(unsafe.issues.count == malformedCases.count + 5)
        precondition(unsafe.issues.contains { $0.contains("Quick Launch cannot guarantee") })

        // A new machine has no installed personas, but its bundled provider
        // models must still be selectable. Broken personas cannot hide models.
        let fresh = ManagedQuickLaunchCatalog.load(configRoot: temporary.appendingPathComponent("fresh"),
                                                   bundledCatalogURL: bundledCatalog)
        precondition(fresh.agents.isEmpty)
        for provider in ManagedQuickLaunchProvider.allCases {
            precondition(!fresh.models(provider: provider).isEmpty)
            precondition(fresh.models(provider: provider) == valid.models(provider: provider))
            precondition(unsafe.models(provider: provider) == valid.models(provider: provider))
        }

        precondition(fresh.issues.isEmpty, "Missing optional agents are normal on a fresh install")
        var directDraft = ManagedQuickLaunchDraft(task: "Fix the launch button", cwd: temporary.path,
                                                  provider: .codex, model: "gpt-5.6-terra")
        for provider in ManagedQuickLaunchProvider.allCases {
            directDraft.provider = provider
            directDraft.model = fresh.models(provider: provider).first!
            guard case .success(let request) = fresh.request(from: directDraft) else {
                fatalError("A complete direct launch must work without installing any agent types")
            }
            precondition(request.agentType == "direct")
            precondition(request.task == directDraft.task, "Direct launch must not inject a persona")
            precondition(request.daemonPayload["agent_type"] as? String == "direct")
            precondition(request.daemonPayload["model"] as? String == directDraft.model)
        }
        let gatewayScript = temporary.appendingPathComponent("gateway-launcher")
        try "#!/bin/sh\nexit 0\n".write(to: gatewayScript, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gatewayScript.path)
        directDraft.provider = .claude
        directDraft.model = "gateway/open-model"
        directDraft.customLauncher = gatewayScript.path
        guard case .success(let gatewayRequest) = fresh.request(from: directDraft) else {
            fatalError("A custom launcher must also work without agent packages")
        }
        precondition(gatewayRequest.customLauncher == gatewayScript.path)
        precondition(gatewayRequest.agentType == "direct")
        precondition(gatewayRequest.task == directDraft.task)
        directDraft.customLauncher = nil
        directDraft.provider = .codex
        directDraft.model = "gpt-5.6-terra"
        directDraft.agentType = "implementer"
        guard case .success(let personaRequest) = valid.request(from: directDraft) else {
            fatalError("Installed personas remain optional launch choices")
        }
        precondition(personaRequest.task.contains(implementation.personaPrompt))
        precondition(personaRequest.agentType == "implementer")
        guard case .failure(let unavailable) = fresh.request(from: directDraft) else {
            fatalError("An explicitly selected missing persona must not silently turn into a direct session")
        }
        precondition(unavailable.issues.contains { $0.field == .agentType })
        directDraft.agentType = ""
        directDraft.model = ""
        guard case .failure(let missingModel) = fresh.request(from: directDraft) else { fatalError("An explicit model is required") }
        precondition(missingModel.issues.contains { $0.field == .model })
        directDraft.model = "gpt-5.6-terra"
        directDraft.task = ""
        guard case .failure(let missingTask) = fresh.request(from: directDraft) else { fatalError("An empty task is invalid") }
        precondition(missingTask.issues.contains { $0.field == .task })

        let absent = ManagedQuickLaunchCatalog.load(configRoot: temporary.appendingPathComponent("missing"),
                                                    bundledCatalogURL: temporary.appendingPathComponent("missing.toml"))
        precondition(absent.agents.isEmpty)
        precondition(!absent.issues.isEmpty)
        precondition(absent.models(provider: .codex).isEmpty)
        let home = URL(fileURLWithPath: "/Users/example")
        precondition(ManagedQuickLaunchCatalog.configRoot(environment: [:], homeDirectory: home).path == "/Users/example/.config/focalpoint")
        precondition(ManagedQuickLaunchCatalog.configRoot(environment: ["XDG_CONFIG_HOME": "/tmp/custom"], homeDirectory: home).path == "/tmp/custom/focalpoint")
        precondition(ManagedQuickLaunchCatalog.configRoot(environment: ["XDG_CONFIG_HOME": ""], homeDirectory: home).path == "/Users/example/.config/focalpoint")
        print("ManagedQuickLaunchCatalogTests: PASS")
    }
}
