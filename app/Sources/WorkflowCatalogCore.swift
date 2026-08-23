// FocalPoint bundled workflow catalog — planning and safe filesystem install.
//
// This file deliberately uses Foundation only so the install contract can be
// tested without launching the app or consulting a real user configuration.

import Foundation

/// Planning/install outcome without Swift.Result: Failure must be Error, and
/// a plain String reason is all these helpers ever produce.
enum CatalogPlanLoad<Payload> {
    case success(Payload)
    case failure(String)
}

struct BundledCatalogInstallPlan: Equatable {
    struct Item: Equatable {
        enum Kind: String, Equatable { case formation, agentType }
        let kind: Kind
        let name: String
        let source: URL
        let destination: URL
    }

    let items: [Item]

    static func formation(name: String, sourceRoot: URL, configRoot: URL,
                          referencedAgentTypes: [String]) -> CatalogPlanLoad<Self> {
        let types = Array(Set(referencedAgentTypes)).sorted()
        return make(items: [(Item.Kind.formation, name)] + types.map { (Item.Kind.agentType, $0) },
                    sourceRoot: sourceRoot, configRoot: configRoot)
    }

    static func agentType(name: String, sourceRoot: URL, configRoot: URL)
        -> CatalogPlanLoad<Self>
    {
        make(items: [(Item.Kind.agentType, name)], sourceRoot: sourceRoot, configRoot: configRoot)
    }

    private static func make(items: [(Item.Kind, String)], sourceRoot: URL,
                             configRoot: URL) -> CatalogPlanLoad<Self> {
        var planned: [Item] = []
        for (kind, name) in items {
            guard isPackageName(name) else { return .failure("Invalid bundled package name '\(name)'.") }
            let folder = kind == .formation ? "workflows" : "agents"
            let source = sourceRoot.appendingPathComponent(folder, isDirectory: true)
                .appendingPathComponent(name, isDirectory: true)
            guard FileManager.default.fileExists(atPath: source.path) else {
                return .failure("Bundled \(kind.rawValue) '\(name)' is unavailable.")
            }
            planned.append(Item(kind: kind, name: name, source: source,
                                destination: configRoot.appendingPathComponent(folder, isDirectory: true)
                                    .appendingPathComponent(name, isDirectory: true)))
        }
        return .success(BundledCatalogInstallPlan(items: planned))
    }

    var collisions: [Item] {
        items.filter { FileManager.default.fileExists(atPath: $0.destination.path) }
    }

    /// Copies only into absent package directories. Every collision is checked
    /// before mutation and rechecked immediately before each copy; no existing
    /// package is replaced, merged, or deleted.
    func install() -> CatalogPlanLoad<Void> {
        let fm = FileManager.default
        if let collision = collisions.first {
            return .failure("Won't overwrite existing \(collision.kind.rawValue) '\(collision.name)'.")
        }
        var copied: [URL] = []
        do {
            for item in items {
                guard !fm.fileExists(atPath: item.destination.path) else {
                    throw CatalogInstallError.message("Won't overwrite existing \(item.kind.rawValue) '\(item.name)'.")
                }
                try fm.createDirectory(at: item.destination.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: item.source, to: item.destination)
                copied.append(item.destination)
            }
            return .success(())
        } catch {
            // Roll back only directories copied by this invocation; preexisting
            // user content is never a rollback target.
            for destination in copied.reversed() { try? fm.removeItem(at: destination) }
            return .failure((error as? CatalogInstallError)?.description ?? error.localizedDescription)
        }
    }

    private static func isPackageName(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

private enum CatalogInstallError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let value) = self { return value }; return "Catalog install failed." }
}
