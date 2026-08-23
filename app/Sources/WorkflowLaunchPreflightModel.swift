// FocalPoint menu-bar app — workflow preflight state and agent-type resolution.
// MIT License.

import Foundation
import Combine

private struct WorkflowAgentTypeProfile {
    let providers: [WorkflowLaunchProvider]

    static func load(typeName: String, agentsDirectory: URL) -> WorkflowAgentTypeProfile? {
        guard !typeName.contains("/"), typeName != ".", typeName != ".." else { return nil }
        let url = agentsDirectory.appendingPathComponent(typeName, isDirectory: true)
            .appendingPathComponent("type.toml")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              case .success(let root) = TomlParser.parse(text),
              case .table(let typeTable)? = root["type"],
              case .string(let declaredName)? = typeTable["name"], declaredName == typeName,
              case .int(let version)? = typeTable["version"], (1...2).contains(version),
              case .table(let providerTable)? = root["provider"],
              case .array(let preferred)? = providerTable["prefer"] else { return nil }

        let providers = preferred.compactMap { value -> WorkflowLaunchProvider? in
            guard case .string(let raw) = value else { return nil }
            return WorkflowLaunchProvider(rawValue: raw)
        }
        guard providers.count == preferred.count, !providers.isEmpty else { return nil }
        return WorkflowAgentTypeProfile(providers: providers)
    }
}

@MainActor
final class WorkflowLaunchPreflightModel: ObservableObject {
    let package: FormationPackage
    let suggestedDirectory: URL?
    let complexity: WorkflowComplexity

    @Published var projectDirectory: URL?
    @Published var orchestratorProvider: WorkflowLaunchProvider
    @Published var orchestratorModel: String
    @Published var roleAssignments: [WorkflowRoleAssignment]
    @Published var fanoutLimit: Int?
    @Published var isReviewingConfirmation = false

    let unresolvedTypes: [String]
    let modelCatalog: ModelCatalog?
    let catalogIssue: String?

    init(package: FormationPackage, suggestedDirectory: URL?) {
        self.package = package
        self.suggestedDirectory = suggestedDirectory
        self.projectDirectory = nil // Selection must always be an explicit human gesture.
        let complexity = WorkflowLaunchRecommendations.complexity(for: package.complexitySignals)
        self.complexity = complexity
        let bundledURL = WorkflowLauncherModel.bundledCatalogDirectory?
            .appendingPathComponent("model-catalog.toml")
        let catalogLoad = bundledURL.map { ModelCatalog.load(bundledURL: $0, userOverrideURL: ModelCatalog.userOverrideURL()) }
        if case .success(let catalog)? = catalogLoad {
            modelCatalog = catalog
            catalogIssue = nil
        } else {
            modelCatalog = nil
            if case .failure(let message)? = catalogLoad { catalogIssue = message }
            else { catalogIssue = "Bundled model catalog resources are unavailable." }
        }
        let orchestrator = modelCatalog.flatMap { catalog -> ModelCatalogSelection? in
            if case .success(let selection) = catalog.recommend(complexity: complexity, agentType: "workflow-orchestrator") { return selection }
            return nil
        }
        self.orchestratorProvider = orchestrator?.provider ?? .codex
        self.orchestratorModel = orchestrator?.model ?? ""

        var unresolved: [String] = []
        // Local capture: the closure below runs while `self` is still
        // mid-initialization, so it must not reference self.modelCatalog.
        let catalog = modelCatalog
        self.roleAssignments = package.allRoles.map { role in
            let profile = WorkflowAgentTypeProfile.load(
                typeName: role.type, agentsDirectory: WorkflowLauncherModel.agentsDirectory
            )
            if profile == nil { unresolved.append(role.type) }
            let selection = catalog.flatMap { catalog -> ModelCatalogSelection? in
                if case .success(let selection) = catalog.recommend(complexity: complexity, agentType: role.type) { return selection }
                return nil
            }
            let provider = selection?.provider ?? profile?.providers.first ?? orchestrator?.provider ?? .codex
            let model = selection?.model ?? ""
            let source = "Resolved by model catalog for \(complexity.title.lowercased()) complexity"
            let gate = role.phaseName.flatMap { phaseName in
                package.phases.first(where: { $0.name == phaseName })?.gate
            } ?? .authorized
            return WorkflowRoleAssignment(
                id: role.id, roleName: role.displayName, typeName: role.type,
                phaseName: role.phaseName, gate: gate, fanoutMaximum: role.fanoutMaximum,
                provider: provider, model: model, sourceDescription: source
            )
        }
        self.unresolvedTypes = unresolved
        if let ceiling = package.fanoutCeiling {
            self.fanoutLimit = WorkflowLaunchRecommendations.fanoutLimit(
                ceiling: ceiling, complexity: complexity
            )
        } else {
            self.fanoutLimit = nil
        }
    }

    var validationErrors: [String] {
        WorkflowPreflightValidation.errors(
            projectDirectory: projectDirectory,
            orchestratorModel: orchestratorModel,
            assignments: roleAssignments,
            fanoutLimit: fanoutLimit,
            fanoutCeiling: package.fanoutCeiling,
            unresolvedTypes: unresolvedTypes
                + (catalogIssue.map { ["Model catalog: \($0)"] } ?? [])
        )
    }

    var canContinue: Bool { validationErrors.isEmpty }

    func setOrchestratorProvider(_ provider: WorkflowLaunchProvider) {
        orchestratorProvider = provider
        orchestratorModel = resolvedModel(provider: provider, agentType: "workflow-orchestrator") ?? ""
        isReviewingConfirmation = false
    }

    func setRoleProvider(_ provider: WorkflowLaunchProvider, at index: Int) {
        guard roleAssignments.indices.contains(index) else { return }
        roleAssignments[index].provider = provider
        roleAssignments[index].model = resolvedModel(provider: provider, agentType: roleAssignments[index].typeName) ?? ""
        isReviewingConfirmation = false
    }

    func makeConfiguration() -> WorkflowLaunchConfiguration? {
        guard validationErrors.isEmpty, let projectDirectory else { return nil }
        return WorkflowLaunchConfiguration(
            projectDirectory: projectDirectory,
            complexity: complexity,
            orchestratorProvider: orchestratorProvider,
            orchestratorModel: orchestratorModel.trimmingCharacters(in: .whitespacesAndNewlines),
            fanoutLimit: fanoutLimit,
            roleAssignments: roleAssignments.map {
                var assignment = $0
                assignment.model = assignment.model.trimmingCharacters(in: .whitespacesAndNewlines)
                return assignment
            }
        )
    }

    private func resolvedModel(provider: WorkflowLaunchProvider, agentType: String) -> String? {
        guard let modelCatalog,
              case .success(let model) = modelCatalog.resolve(provider: provider, complexity: complexity, agentType: agentType) else { return nil }
        return model
    }
}
