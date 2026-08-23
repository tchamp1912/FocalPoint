// FocalPoint menu-bar app — validated explicit provider model catalog.
// MIT License.

import Foundation

/// A catalog key is deliberately the complete semantic launch choice. There
/// is no wildcard/provider-default lookup: absence is a launch error.
struct ModelCatalogKey: Hashable, Equatable {
    let provider: WorkflowLaunchProvider
    let complexity: WorkflowComplexity
    let agentType: String
}

struct ModelCatalogResolutionKey: Hashable, Equatable {
    let complexity: WorkflowComplexity
    let agentType: String
}

struct ModelCatalogSelection: Equatable {
    let provider: WorkflowLaunchProvider
    let complexity: WorkflowComplexity
    let agentType: String
    let model: String

    var key: ModelCatalogKey { .init(provider: provider, complexity: complexity, agentType: agentType) }
}

enum ModelCatalogLoad: Equatable {
    case success(ModelCatalog)
    case failure(String)
}

enum ModelCatalogResolution: Equatable {
    case success(String)
    case failure(String)
}

/// Loads one bundled catalog with an optional, exact-key user overlay. A bad
/// overlay invalidates the whole resolver — it must never degrade to ambient
/// provider state or silently ignore a user pin.
struct ModelCatalog: Equatable {
    private let selections: [ModelCatalogKey: String]
    private let recommendations: [ModelCatalogResolutionKey: WorkflowLaunchProvider]

    static func load(bundledURL: URL, userOverrideURL: URL? = nil) -> ModelCatalogLoad {
        switch parse(url: bundledURL, label: "Bundled model catalog") {
        case .failure(let message): return .failure(message)
        case .success(let bundled):
            var merged = bundled.selections
            var recommendations = bundled.recommendations
            if let userOverrideURL, FileManager.default.fileExists(atPath: userOverrideURL.path) {
                switch parse(url: userOverrideURL, label: "User model catalog") {
                case .failure(let message): return .failure(message)
                case .success(let user):
                    for (key, model) in user.selections { merged[key] = model }
                    for (key, provider) in user.recommendations { recommendations[key] = provider }
                }
            }
            for (key, provider) in recommendations {
                let modelKey = ModelCatalogKey(provider: provider, complexity: key.complexity, agentType: key.agentType)
                guard merged[modelKey] != nil else {
                    return .failure("\(label(userOverrideURL)) selects a provider with no concrete model entry.")
                }
            }
            return .success(.init(selections: merged, recommendations: recommendations))
        }
    }

    func recommend(complexity: WorkflowComplexity, agentType: String) -> ModelCatalogRecommendation {
        let key = ModelCatalogResolutionKey(complexity: complexity, agentType: agentType)
        guard let provider = recommendations[key] else { return .failure }
        switch resolve(provider: provider, complexity: complexity, agentType: agentType) {
        case .success(let model): return .success(.init(provider: provider, complexity: complexity, agentType: agentType, model: model))
        case .failure: return .failure
        }
    }

    func resolve(provider: WorkflowLaunchProvider, complexity: WorkflowComplexity,
                 agentType: String) -> ModelCatalogResolution {
        let key = ModelCatalogKey(provider: provider, complexity: complexity, agentType: agentType)
        guard let model = selections[key] else {
            return .failure("No explicit model catalog selection for \(provider.rawValue), \(complexity.rawValue), agent type '\(agentType)'.")
        }
        return .success(model)
    }

    static func userOverrideURL(fileManager: FileManager = .default) -> URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".config", isDirectory: true)
        return configHome.appendingPathComponent("focalpoint/model-catalog.toml")
    }

    private init(selections: [ModelCatalogKey: String], recommendations: [ModelCatalogResolutionKey: WorkflowLaunchProvider]) {
        self.selections = selections
        self.recommendations = recommendations
    }

    private struct Parsed { let selections: [ModelCatalogKey: String]; let recommendations: [ModelCatalogResolutionKey: WorkflowLaunchProvider] }
    private enum ParsedLoad { case success(Parsed); case failure(String) }
    private static func label(_ url: URL?) -> String { url == nil ? "Bundled model catalog" : "User model catalog" }

    private static func parse(url: URL, label: String) -> ParsedLoad {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure("\(label) is unavailable at \(url.path).")
        }
        guard case .success(let root) = TomlParser.parse(text),
              case .table(let header)? = root["catalog"],
              case .int(1)? = header["version"],
              case .tableArray(let rows)? = root["selection"], !rows.isEmpty,
              case .tableArray(let resolutionRows)? = root["resolution"], !resolutionRows.isEmpty else {
            return .failure("\(label) is malformed or uses an unsupported version.")
        }
        var selections: [ModelCatalogKey: String] = [:]
        for row in rows {
            guard row.count == 4,
                  case .string(let providerRaw)? = row["provider"],
                  let provider = WorkflowLaunchProvider(rawValue: providerRaw),
                  case .string(let complexityRaw)? = row["complexity"],
                  let complexity = WorkflowComplexity(rawValue: complexityRaw),
                  case .string(let agentType)? = row["agent_type"], validAgentType(agentType),
                  case .string(let model)? = row["model"], validModel(model) else {
                return .failure("\(label) contains an invalid selection.")
            }
            let key = ModelCatalogKey(provider: provider, complexity: complexity, agentType: agentType)
            guard selections[key] == nil else {
                return .failure("\(label) duplicates a provider/complexity/agent-type selection.")
            }
            selections[key] = model
        }
        var recommendations: [ModelCatalogResolutionKey: WorkflowLaunchProvider] = [:]
        for row in resolutionRows {
            guard row.count == 3,
                  case .string(let providerRaw)? = row["provider"], let provider = WorkflowLaunchProvider(rawValue: providerRaw),
                  case .string(let complexityRaw)? = row["complexity"], let complexity = WorkflowComplexity(rawValue: complexityRaw),
                  case .string(let agentType)? = row["agent_type"], validAgentType(agentType) else {
                return .failure("\(label) contains an invalid provider resolution.")
            }
            let key = ModelCatalogResolutionKey(complexity: complexity, agentType: agentType)
            guard recommendations[key] == nil else { return .failure("\(label) duplicates a complexity/agent-type resolution.") }
            recommendations[key] = provider
        }
        return .success(Parsed(selections: selections, recommendations: recommendations))
    }

    static func validAgentType(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
            && !["auto", "default", "general", "provider-default"].contains(value.lowercased())
    }

    static func validModel(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._/@:-]{0,127}$", options: .regularExpression) != nil
            && !["auto", "default", "general", "provider-default"].contains(value.lowercased())
    }
}

enum ModelCatalogRecommendation: Equatable {
    case success(ModelCatalogSelection)
    case failure
}
