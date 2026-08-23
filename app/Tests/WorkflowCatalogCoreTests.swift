import Foundation

@main
enum WorkflowCatalogCoreTests {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WorkflowCatalogCoreTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundled", isDirectory: true)
        let config = root.appendingPathComponent("temp-config", isDirectory: true)

        try fm.createDirectory(at: bundled.appendingPathComponent("workflows/ui-check", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: bundled.appendingPathComponent("agents/scout", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: bundled.appendingPathComponent("agents/verifier", isDirectory: true),
                               withIntermediateDirectories: true)
        try "workflow".write(to: bundled.appendingPathComponent("workflows/ui-check/formation.toml"),
                               atomically: true, encoding: .utf8)
        try "scout".write(to: bundled.appendingPathComponent("agents/scout/type.toml"),
                            atomically: true, encoding: .utf8)
        try "verifier".write(to: bundled.appendingPathComponent("agents/verifier/type.toml"),
                               atomically: true, encoding: .utf8)

        guard case .success(let plan) = BundledCatalogInstallPlan.formation(
            name: "ui-check", sourceRoot: bundled, configRoot: config,
            referencedAgentTypes: ["verifier", "scout", "verifier"]
        ) else { fatalError("expected valid temporary install plan") }
        precondition(plan.items.map(\.name) == ["ui-check", "scout", "verifier"])
        precondition(plan.collisions.isEmpty)
        guard case .success = plan.install() else { fatalError("expected temporary install to succeed") }
        precondition(fm.fileExists(atPath: config.appendingPathComponent("workflows/ui-check/formation.toml").path))
        precondition(fm.fileExists(atPath: config.appendingPathComponent("agents/scout/type.toml").path))
        precondition(fm.fileExists(atPath: config.appendingPathComponent("agents/verifier/type.toml").path))

        // A second install is a collision, and the installed file remains untouched.
        guard case .failure(let collision) = plan.install() else { fatalError("collision must fail") }
        precondition(collision.contains("Won't overwrite"))
        let installed = try String(contentsOf: config.appendingPathComponent("agents/scout/type.toml"))
        precondition(installed == "scout")

        guard case .success(let repeatPlan) = BundledCatalogInstallPlan.formation(
            name: "ui-check", sourceRoot: bundled, configRoot: config, referencedAgentTypes: []
        ) else { fatalError("repeat plan should succeed") }
        precondition(repeatPlan.collisions.map(\.name) == ["ui-check"])

        guard case .failure(let invalid) = BundledCatalogInstallPlan.agentType(
            name: "../escape", sourceRoot: bundled, configRoot: config
        ) else { fatalError("traversal-like name must fail planning") }
        precondition(invalid.contains("Invalid"))
        print("WorkflowCatalogCoreTests: passed")
    }
}
