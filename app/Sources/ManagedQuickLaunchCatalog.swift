// FocalPoint quick launcher — installed agent choices and shared model policy.
// Foundation only; discovery does not install packages or modify configuration.
// MIT License.

import Foundation

struct ManagedQuickLaunchAgentOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let preferredProviders: [ManagedQuickLaunchProvider]
    let personaPrompt: String
}

struct ManagedQuickLaunchCatalog {
    let agents: [ManagedQuickLaunchAgentOption]
    let issues: [String]
    private let modelCatalog: ModelCatalog?

    static func configRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = environment["XDG_CONFIG_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".config", isDirectory: true)
        return base.appendingPathComponent("focalpoint", isDirectory: true)
    }

    static func load(configRoot: URL? = nil, bundledCatalogURL: URL? = nil) -> Self {
        let root = configRoot ?? Self.configRoot()
        let agentsDirectory = root.appendingPathComponent("agents", isDirectory: true)
        var issues: [String] = []
        var agents: [ManagedQuickLaunchAgentOption] = []
        do {
            let directories = FileManager.default.fileExists(atPath: agentsDirectory.path)
                ? try FileManager.default.contentsOfDirectory(
                at: agentsDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent } : []
            for directory in directories {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                do {
                    agents.append(try loadAgent(directory: directory))
                } catch {
                    issues.append("\(directory.lastPathComponent): \(error.localizedDescription)")
                }
            }
        } catch {
            issues.append("Installed agents could not be read at \(agentsDirectory.path).")
        }
        agents.sort {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }

        let bundledURL = bundledCatalogURL ?? Bundle.main.resourceURL?
            .appendingPathComponent("BundledPackages/model-catalog.toml")
        var modelCatalog: ModelCatalog?
        if let bundledURL {
            switch ModelCatalog.load(bundledURL: bundledURL,
                                     userOverrideURL: root.appendingPathComponent("model-catalog.toml")) {
            case .success(let catalog): modelCatalog = catalog
            case .failure(let message): issues.append(message)
            }
        } else {
            issues.append("The bundled model catalog is unavailable.")
        }
        return Self(agents: agents, issues: issues, modelCatalog: modelCatalog)
    }

    /// Model availability belongs to the provider, independent of agent packages.
    func models(provider: ManagedQuickLaunchProvider) -> [String] {
        guard let catalog = modelCatalog,
              let workflowProvider = WorkflowLaunchProvider(rawValue: provider.rawValue) else { return [] }
        return catalog.models(provider: workflowProvider)
    }

    func recommendation(provider: ManagedQuickLaunchProvider?, agentType: String,
                        complexity: ManagedQuickLaunchComplexity) -> ManagedQuickLaunchRecommendation? {
        guard agents.contains(where: { $0.id == agentType }), let catalog = modelCatalog else { return nil }
        let workflowComplexity: WorkflowComplexity
        let resolvedComplexity: ManagedQuickLaunchComplexity
        switch complexity {
        case .simple: workflowComplexity = .focused; resolvedComplexity = .simple
        case .infer, .standard: workflowComplexity = .substantial; resolvedComplexity = .standard
        case .complex: workflowComplexity = .complex; resolvedComplexity = .complex
        }
        let selectedProvider: ManagedQuickLaunchProvider
        let model: String
        if let provider {
            guard let workflowProvider = WorkflowLaunchProvider(rawValue: provider.rawValue),
                  case .success(let selectedModel) = catalog.resolve(
                    provider: workflowProvider, complexity: workflowComplexity, agentType: agentType
                  ) else { return nil }
            selectedProvider = provider
            model = selectedModel
        } else {
            guard case .success(let selection) = catalog.recommend(complexity: workflowComplexity, agentType: agentType),
                  let provider = ManagedQuickLaunchProvider(rawValue: selection.provider.rawValue) else { return nil }
            selectedProvider = provider
            model = selection.model
        }
        return .init(complexity: resolvedComplexity, agentType: agentType,
                     provider: selectedProvider, model: model,
                     rationale: "Selected from your model catalog for this agent and task complexity.")
    }

    /// A direct session needs no installed persona. Keep an explicit transport
    /// type for daemon/workflow bookkeeping without inventing agent instructions.
    func request(from draft: ManagedQuickLaunchDraft) -> Result<ManagedQuickLaunchRequest, ManagedQuickLaunchValidationFailure> {
        guard !draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.init(issues: [.init(field: .model, message: "Choose a model or enter a custom model ID.")]))
        }
        var resolved = draft
        let persona: String?
        if draft.agentType.isEmpty {
            resolved.agentType = "direct"
            persona = nil
        } else if let agent = agents.first(where: { $0.id == draft.agentType }) {
            persona = agent.personaPrompt
        } else {
            return .failure(.init(issues: [.init(field: .agentType,
                message: "The selected agent type is unavailable. Choose another type or No added instructions.")]))
        }
        return ManagedQuickLaunchRules.request(from: resolved, personaPrompt: persona)
    }

    private static func loadAgent(directory: URL) throws -> ManagedQuickLaunchAgentOption {
        let text: String
        do { text = try String(contentsOf: directory.appendingPathComponent("type.toml"), encoding: .utf8) }
        catch { throw CatalogError("type.toml is missing or unreadable.") }
        guard case .success(let root) = TomlParser.parse(text) else {
            throw CatalogError("type.toml is malformed.")
        }
        guard case .table(let header)? = root["type"],
              let name = string(header["name"]), ModelCatalog.validAgentType(name),
              name.count <= 64, name == directory.lastPathComponent,
              case .int(let version)? = header["version"], version > 0,
              let description = string(header["description"]), !description.isEmpty else {
            throw CatalogError("[type] needs a name matching its folder, a positive version, and a description.")
        }
        guard case .table(let provider)? = root["provider"],
              let preferredNames = strings(provider["prefer"]), !preferredNames.isEmpty,
              Set(preferredNames).count == preferredNames.count else {
            throw CatalogError("[provider] needs a nonempty, unique prefer list.")
        }
        let preferred = preferredNames.compactMap(ManagedQuickLaunchProvider.init(rawValue:))
        guard preferred.count == preferredNames.count else { throw CatalogError("[provider] contains an unknown provider.") }
        if let requires = provider["requires"], strings(requires) == nil {
            throw CatalogError("[provider] requires must be a string list.")
        }
        if let model = provider["model"], string(model) == nil {
            throw CatalogError("[provider] model must be a string.")
        }
        guard case .table(let persona)? = root["persona"],
              let title = string(persona["title"]), !title.isEmpty,
              let prompt = string(persona["prompt"]), validRelativePath(prompt) else {
            throw CatalogError("[persona] needs a title and a relative prompt path.")
        }
        if let rawEnforced = root["enforced"] {
            guard case .table(let enforced) = rawEnforced else {
                throw CatalogError("[enforced] must be a table.")
            }
            guard enforced.isEmpty else {
                throw CatalogError("This agent requires enforced constraints. Quick Launch cannot guarantee them; use a workflow that supports those constraints.")
            }
        }
        let agentDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let personaURL = directory.appendingPathComponent(prompt).resolvingSymlinksInPath().standardizedFileURL
        guard personaURL.path.hasPrefix(agentDirectory.path + "/") else {
            throw CatalogError("The persona prompt must stay inside its agent folder, including through symbolic links.")
        }
        let limit = 16_384
        let personaData: Data
        do {
            guard (try personaURL.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                throw CatalogError("The persona prompt must be a regular file.")
            }
            let file = try FileHandle(forReadingFrom: personaURL)
            defer { try? file.close() }
            personaData = try file.read(upToCount: limit + 1) ?? Data()
        } catch {
            throw CatalogError("The persona prompt is missing or unreadable.")
        }
        guard personaData.count <= limit,
              let personaPrompt = String(data: personaData, encoding: .utf8),
              !personaPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !personaPrompt.contains("\0") else {
            throw CatalogError("The persona prompt must contain 1–16,384 UTF-8 bytes and no null characters.")
        }
        return .init(id: name, displayName: title, description: description,
                     preferredProviders: preferred, personaPrompt: personaPrompt)
    }

    private static func string(_ value: TomlValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strings(_ value: TomlValue?) -> [String]? {
        guard case .array(let values) = value else { return nil }
        let strings = values.compactMap(string)
        return strings.count == values.count ? strings : nil
    }

    private static func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\0")
            && !value.split(separator: "/").contains("..")
    }

    private struct CatalogError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
