// FocalPoint history workspace — typed records, queries, grouping, and actions.
// This file intentionally has no dependency on AppModel so the workspace can
// be integrated with either persisted daemon history or previews/tests.

import Foundation

enum HistoryProvider: String, CaseIterable, Codable, Hashable, Identifiable {
    case claude
    case codex
    case cursor
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .gemini: return "sparkle"
        }
    }

    var supportsResume: Bool { self != .cursor }

    func resumeCommand(sessionID: String) -> String? {
        let quotedID = "'" + sessionID.replacingOccurrences(of: "'", with: "'\\''") + "'"
        switch self {
        case .claude: return "claude --resume \(quotedID)"
        case .codex: return "codex resume \(quotedID)"
        case .gemini: return "gemini --resume \(quotedID)"
        case .cursor: return nil
        }
    }

}

enum HistoryRunState: String, CaseIterable, Codable, Hashable, Identifiable {
    case completed
    case failed
    case cancelled
    case interrupted

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .interrupted: return "Interrupted"
        }
    }

    var symbolName: String {
        switch self {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "minus.circle.fill"
        case .interrupted: return "bolt.slash.fill"
        }
    }
}

struct HistoryProject: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var path: String
}

struct HistoryWorkflow: Identifiable, Codable, Hashable {
    let id: String
    var name: String
}

struct HistoryUsageSummary: Codable, Hashable {
    var tokensIn: Int
    var tokensOut: Int
    var toolCalls: Int
    var estimatedCostUSD: Double?

    var totalTokens: Int { tokensIn + tokensOut }
}

struct HistoryRecord: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var summary: String
    var provider: HistoryProvider
    var model: String
    var state: HistoryRunState
    var project: HistoryProject
    var workflow: HistoryWorkflow?
    var startedAt: Date
    var endedAt: Date
    var usage: HistoryUsageSummary
    var sourcePrompt: String?
    var resumeToken: String?
    var isPinned: Bool

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }
    var isResumeEligible: Bool {
        resumeToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && provider.supportsResume
    }
    var isRerunEligible: Bool {
        sourcePrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

enum HistoryGrouping: String, CaseIterable, Identifiable {
    case project
    case workflow

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

struct HistoryQuery: Equatable {
    var text = ""
    var providers: Set<HistoryProvider> = []
    var states: Set<HistoryRunState> = []
    var projectIDs: Set<String> = []

    var isFiltered: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !providers.isEmpty || !states.isEmpty || !projectIDs.isEmpty
    }
}

struct HistoryGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let records: [HistoryRecord]
    let isPinnedGroup: Bool
}

enum HistoryLaunchMode: String, Identifiable {
    case resume
    case rerun

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

struct HistoryLaunchRequest: Equatable {
    let sourceRecordID: String
    let mode: HistoryLaunchMode
    let project: HistoryProject
    let provider: HistoryProvider
    let model: String
    let resumeToken: String?
    let sourcePrompt: String?
}

enum HistoryWorkspaceAction: Equatable {
    case pin(recordID: String, isPinned: Bool)
    case delete(recordIDs: Set<String>)
    case launch(HistoryLaunchRequest)
}

struct HistoryLaunchOption: Identifiable, Hashable {
    let provider: HistoryProvider
    let model: String
    var id: String { "\(provider.rawValue):\(model)" }
}

enum HistoryWorkspaceQuery {
    static func filter(_ records: [HistoryRecord], by query: HistoryQuery) -> [HistoryRecord] {
        let terms = query.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }

        return records.filter { record in
            guard query.providers.isEmpty || query.providers.contains(record.provider),
                  query.states.isEmpty || query.states.contains(record.state),
                  query.projectIDs.isEmpty || query.projectIDs.contains(record.project.id)
            else { return false }

            guard !terms.isEmpty else { return true }
            let haystack = [
                record.title, record.summary, record.provider.displayName, record.model,
                record.project.name, record.project.path, record.workflow?.name ?? "",
                record.sourcePrompt ?? ""
            ].joined(separator: " ").lowercased()
            return terms.allSatisfy(haystack.contains)
        }
        .sorted(by: recordOrder)
    }

    static func groups(
        for records: [HistoryRecord],
        grouping: HistoryGrouping
    ) -> [HistoryGroup] {
        let sorted = records.sorted(by: recordOrder)
        let pinned = sorted.filter(\.isPinned)
        let ordinary = sorted.filter { !$0.isPinned }
        var result: [HistoryGroup] = []

        if !pinned.isEmpty {
            result.append(HistoryGroup(
                id: "pinned", title: "Pinned", subtitle: "Kept close at hand",
                records: pinned, isPinnedGroup: true
            ))
        }

        let grouped = Dictionary(grouping: ordinary) { record -> String in
            switch grouping {
            case .project: return record.project.id
            case .workflow: return record.workflow?.id ?? "ungrouped"
            }
        }

        let remaining = grouped.map { key, values -> HistoryGroup in
            let newest = values.sorted(by: recordOrder)
            let first = newest[0]
            switch grouping {
            case .project:
                return HistoryGroup(
                    id: "project:\(key)", title: first.project.name,
                    subtitle: first.project.path, records: newest, isPinnedGroup: false
                )
            case .workflow:
                return HistoryGroup(
                    id: "workflow:\(key)",
                    title: first.workflow?.name ?? "No workflow",
                    subtitle: first.workflow == nil ? "One-off sessions" : first.project.name,
                    records: newest, isPinnedGroup: false
                )
            }
        }
        .sorted { lhs, rhs in
            let leftDate = lhs.records.first?.endedAt ?? .distantPast
            let rightDate = rhs.records.first?.endedAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        result.append(contentsOf: remaining)
        return result
    }

    static func summary(for records: [HistoryRecord]) -> HistoryCollectionSummary {
        HistoryCollectionSummary(
            runCount: records.count,
            projectCount: Set(records.map(\.project.id)).count,
            duration: records.reduce(0) { $0 + $1.duration },
            tokens: records.reduce(0) { $0 + $1.usage.totalTokens },
            estimatedCostUSD: records.compactMap(\.usage.estimatedCostUSD).reduce(0, +)
        )
    }

    private static func recordOrder(_ lhs: HistoryRecord, _ rhs: HistoryRecord) -> Bool {
        if lhs.endedAt != rhs.endedAt { return lhs.endedAt > rhs.endedAt }
        return lhs.id < rhs.id
    }
}

struct HistoryCollectionSummary: Equatable {
    let runCount: Int
    let projectCount: Int
    let duration: TimeInterval
    let tokens: Int
    let estimatedCostUSD: Double
}

enum HistoryWorkspaceSamples {
    private static let anchor = Date(timeIntervalSince1970: 1_787_400_000)
    private static let focalPoint = HistoryProject(
        id: "focalpoint", name: "FocalPoint", path: "/Users/demo/Projects/focalpoint"
    )
    private static let atlas = HistoryProject(
        id: "atlas", name: "Atlas", path: "/Users/demo/Projects/atlas"
    )

    static let projects = [focalPoint, atlas]
    static let launchOptions = [
        HistoryLaunchOption(provider: .claude, model: "claude-opus-4-1"),
        HistoryLaunchOption(provider: .claude, model: "claude-sonnet-4"),
        HistoryLaunchOption(provider: .codex, model: "gpt-5.2-codex"),
        HistoryLaunchOption(provider: .codex, model: "gpt-5.2"),
        HistoryLaunchOption(provider: .cursor, model: "composer-2")
    ]

    static let records: [HistoryRecord] = [
        record("hist-001", "History workspace", "Built grouped history with explicit relaunch configuration.",
               .codex, "gpt-5.2-codex", .completed, focalPoint, "UX roadmap", 18_600, 1_540,
               184_220, 52_810, 37, 4.82, "Implement product area 6 end to end.", "codex-session-001", true),
        record("hist-002", "Provider telemetry", "Found a stale reset timestamp and added a bounded fallback.",
               .claude, "claude-opus-4-1", .completed, focalPoint, "Release hardening", 86_400, 2_820,
               98_500, 21_300, 24, 2.41, "Audit provider usage telemetry.", "claude-session-002", false),
        record("hist-003", "Sidebar navigation", "Stopped after the settings window failed its snapshot check.",
               .cursor, "composer-2", .failed, atlas, nil, 172_800, 760,
               31_100, 8_900, 9, nil, "Polish the settings sidebar.", nil, false),
        record("hist-004", "Workflow schema audit", "Validated all formation packages and documented two migration risks.",
               .claude, "claude-sonnet-4", .completed, focalPoint, "Workflow formations", 259_200, 3_960,
               143_600, 35_400, 41, 3.16, "Review workflow schema compatibility.", "claude-session-004", false),
        record("hist-005", "Release note draft", "The session was stopped before a final draft was produced.",
               .codex, "gpt-5.2", .interrupted, atlas, nil, 345_600, 520,
               18_200, 4_100, 5, 0.42, "Draft release notes from the changelog.", "codex-session-005", false)
    ]

    private static func record(
        _ id: String, _ title: String, _ summary: String,
        _ provider: HistoryProvider, _ model: String, _ state: HistoryRunState,
        _ project: HistoryProject, _ workflow: String?, _ age: TimeInterval,
        _ duration: TimeInterval, _ tokensIn: Int, _ tokensOut: Int, _ tools: Int,
        _ cost: Double?, _ prompt: String?, _ resumeToken: String?, _ pinned: Bool
    ) -> HistoryRecord {
        let ended = anchor.addingTimeInterval(-age)
        return HistoryRecord(
            id: id, title: title, summary: summary, provider: provider, model: model,
            state: state, project: project,
            workflow: workflow.map { HistoryWorkflow(id: $0.lowercased().replacingOccurrences(of: " ", with: "-"), name: $0) },
            startedAt: ended.addingTimeInterval(-duration), endedAt: ended,
            usage: HistoryUsageSummary(tokensIn: tokensIn, tokensOut: tokensOut,
                                        toolCalls: tools, estimatedCostUSD: cost),
            sourcePrompt: prompt, resumeToken: resumeToken, isPinned: pinned
        )
    }
}
