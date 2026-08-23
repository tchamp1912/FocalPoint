import Foundation

@main
enum WorkflowLaunchPreflightCoreTests {
    static func main() {
        assert(WorkflowLaunchRecommendations.complexity(for: .init(
            fixedRoleCount: 1, phaseCount: 0, fanoutCeiling: nil,
            confirmationGateCount: 0
        )) == .focused)
        assert(WorkflowLaunchRecommendations.complexity(for: .init(
            fixedRoleCount: 2, phaseCount: 2, fanoutCeiling: nil,
            confirmationGateCount: 1
        )) == .substantial)
        assert(WorkflowLaunchRecommendations.complexity(for: .init(
            fixedRoleCount: 2, phaseCount: 2, fanoutCeiling: 5,
            confirmationGateCount: 1
        )) == .complex)

        for complexity in WorkflowComplexity.allCases {
            let recommendation = WorkflowLaunchRecommendations.orchestrator(for: complexity)
            assert(!recommendation.1.isEmpty)
            for provider in WorkflowLaunchProvider.allCases {
                assert(!WorkflowLaunchRecommendations.model(
                    for: provider, complexity: complexity
                ).isEmpty)
            }
        }
        assert(WorkflowLaunchRecommendations.fanoutLimit(
            ceiling: 9, complexity: .substantial
        ) == 3)

        let missing = WorkflowPreflightValidation.errors(
            projectDirectory: nil, orchestratorModel: "",
            assignments: [], fanoutLimit: nil, fanoutCeiling: 4,
            unresolvedTypes: ["reviewer", "reviewer"]
        )
        assert(missing.contains { $0.contains("project folder") })
        assert(missing.contains { $0.contains("orchestrator model") })
        assert(missing.filter { $0.contains("reviewer") }.count == 1)
        assert(missing.contains { $0.contains("between 1 and 4") })

        let valid = WorkflowPreflightValidation.errors(
            projectDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            orchestratorModel: "gpt-5.6-sol",
            assignments: [WorkflowRoleAssignment(
                id: "review", roleName: "Review", typeName: "reviewer",
                phaseName: nil, gate: .authorized, fanoutMaximum: nil, provider: .codex,
                model: "gpt-5.6-sol", sourceDescription: "test"
            )],
            fanoutLimit: 2, fanoutCeiling: 4, unresolvedTypes: []
        )
        assert(valid.isEmpty, "unexpected validation errors: \(valid)")

        let assignment = WorkflowRoleAssignment(
            id: "review:reviewer:0", roleName: "Review", typeName: "reviewer",
            phaseName: "review", gate: .confirm, fanoutMaximum: 5, provider: .codex,
            model: "gpt-5.6-sol", sourceDescription: "test"
        )
        let configuration = WorkflowLaunchConfiguration(
            projectDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            complexity: .complex, orchestratorProvider: .codex,
            orchestratorModel: "gpt-5.6-sol", fanoutLimit: 3,
            roleAssignments: [assignment]
        )
        let manifest = configuration.daemonAssignmentManifest[0]
        assert(manifest["assignment_id"] as? String == "review:reviewer:0")
        assert(manifest["gate"] as? String == "confirm")
        assert(manifest["fanout"] as? Bool == true)
        assert(manifest["fanout_limit"] as? Int == 3)
        print("WorkflowLaunchPreflightCoreTests: passed")
    }
}
