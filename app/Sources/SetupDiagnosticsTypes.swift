// FocalPoint setup diagnostics — typed checks, actions, and redacted reports.
// MIT License.

import Foundation

enum SetupDiagnosticID: String, CaseIterable, Codable, Sendable, Identifiable {
    case daemon
    case adapters
    case tmux
    case permissions
    case loginStartup
    case providers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daemon: "Daemon connectivity"
        case .adapters: "Agent adapters"
        case .tmux: "Managed sessions (tmux)"
        case .permissions: "macOS permissions"
        case .loginStartup: "Startup at login"
        case .providers: "Provider connections"
        }
    }

    var systemImage: String {
        switch self {
        case .daemon: "server.rack"
        case .adapters: "point.3.connected.trianglepath.dotted"
        case .tmux: "terminal"
        case .permissions: "hand.raised"
        case .loginStartup: "power"
        case .providers: "person.crop.circle.badge.checkmark"
        }
    }
}

enum SetupDiagnosticStatus: String, Codable, Sendable {
    case notRun
    case running
    case passed
    case warning
    case failed

    var label: String {
        switch self {
        case .notRun: "Not checked"
        case .running: "Checking…"
        case .passed: "Ready"
        case .warning: "Review"
        case .failed: "Needs attention"
        }
    }
}

struct SetupDiagnosticEvidence: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let label: String
    let value: String

    init(_ label: String, _ value: String, id: UUID = UUID()) {
        self.id = id
        self.label = SetupDiagnosticsRedactor.redact(label)
        self.value = SetupDiagnosticsRedactor.redact(value)
    }
}

enum SetupDiagnosticActionKind: String, Codable, Sendable {
    case recheck
    case copyInstallCommand
    case copyTmuxInstallCommand
    case openAccessibilitySettings
    case openAutomationSettings
    case openLoginItemsSettings
    case revealFocalPointConfig
    case openProviderSetupGuide
    case startDaemon
    case enableAppLogin
}

struct SetupDiagnosticAction: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let title: String
    let kind: SetupDiagnosticActionKind
    let isPrimary: Bool

    init(_ kind: SetupDiagnosticActionKind, title: String, isPrimary: Bool = false) {
        self.id = kind.rawValue
        self.title = title
        self.kind = kind
        self.isPrimary = isPrimary
    }
}

struct SetupDiagnosticResult: Identifiable, Codable, Sendable, Equatable {
    let id: SetupDiagnosticID
    let status: SetupDiagnosticStatus
    let summary: String
    let evidence: [SetupDiagnosticEvidence]
    let actions: [SetupDiagnosticAction]
    let checkedAt: Date

    init(id: SetupDiagnosticID,
         status: SetupDiagnosticStatus,
         summary: String,
         evidence: [SetupDiagnosticEvidence] = [],
         actions: [SetupDiagnosticAction] = [],
         checkedAt: Date = Date()) {
        self.id = id
        self.status = status
        self.summary = SetupDiagnosticsRedactor.redact(summary)
        self.evidence = evidence
        self.actions = actions
        self.checkedAt = checkedAt
    }

    static func pending(_ id: SetupDiagnosticID) -> Self {
        .init(id: id, status: .notRun, summary: "Run checks to inspect this area.")
    }

    static func running(_ id: SetupDiagnosticID) -> Self {
        .init(id: id, status: .running, summary: "Checking local setup…")
    }
}

struct SetupDiagnosticActionOutcome: Sendable, Equatable {
    let succeeded: Bool
    let message: String
    let shouldRecheck: Bool

    init(succeeded: Bool, message: String, shouldRecheck: Bool = false) {
        self.succeeded = succeeded
        self.message = SetupDiagnosticsRedactor.redact(message)
        self.shouldRecheck = shouldRecheck
    }
}

protocol SetupDiagnosticChecking: Sendable {
    var id: SetupDiagnosticID { get }
    func run() async -> SetupDiagnosticResult
}

protocol SetupDiagnosticActionPerforming: Sendable {
    func perform(_ action: SetupDiagnosticAction) async -> SetupDiagnosticActionOutcome
}

/// Central safety boundary for every string shown or copied by diagnostics.
/// Probes intentionally collect only booleans and coarse labels; this second
/// layer removes home paths, credential-shaped assignments, and common token
/// forms in case a future probe accidentally supplies them.
enum SetupDiagnosticsRedactor {
    static func redact(_ input: String, limit: Int = 1_000) -> String {
        var output = input.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let patterns = [
            #"(?i)\b(api[_-]?key|access[_-]?token|auth[_-]?token|secret|password)\s*[:=]\s*[^\s,;]+"#,
            #"\b(sk|sk-ant|ghp|github_pat)-[A-Za-z0-9_-]{8,}\b"#,
            #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(in: output,
                                                    range: range,
                                                    withTemplate: "[REDACTED]")
        }
        // Operational logs historically included labels and working paths.
        // They are useful locally but never belong in a public issue body.
        let privateFieldPattern = #"(?i)\b(title|label|cwd|prompt|body|text|project)=.*?(?=\s[a-z_][a-z0-9_]*=|$)"#
        if let regex = try? NSRegularExpression(pattern: privateFieldPattern) {
            let range = NSRange(output.startIndex..., in: output)
            output = regex.stringByReplacingMatches(in: output,
                                                    range: range,
                                                    withTemplate: "$1=[REDACTED]")
        }
        return String(output.prefix(max(0, limit)))
    }
}

struct SetupDiagnosticsReport {
    static func text(results: [SetupDiagnosticResult], generatedAt: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "FocalPoint setup diagnostics",
            "Generated: \(formatter.string(from: generatedAt))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(machineArchitecture())",
            "No credentials, environment values, session content, or raw configuration are included.",
            ""
        ]
        for result in results {
            lines.append("[\(result.status.label)] \(result.id.title): \(result.summary)")
            for item in result.evidence {
                lines.append("  - \(item.label): \(item.value)")
            }
        }
        return SetupDiagnosticsRedactor.redact(lines.joined(separator: "\n"), limit: 50_000)
    }

    private static func machineArchitecture() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

/// Gemini's lifecycle hooks are nested command groups, with a separate
/// global enable switch. A path mentioned elsewhere is not a wired hook.
enum GeminiHookDiagnostics {
    static func sessionStartConfigured(_ data: Data, marker: String) -> Bool {
        // Gemini accepts comments in settings.json. Foundation's JSON5 reader
        // understands them without treating comment-like text in strings as syntax.
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any],
              let groups = hooks["SessionStart"] as? [[String: Any]] else { return false }
        let config = root["hooksConfig"] as? [String: Any]
        guard config?["enabled"] as? Bool != false else { return false }
        let disabled = Set(config?["disabled"] as? [String] ?? [])
        return groups.contains { group in
            guard let commands = group["hooks"] as? [[String: Any]] else { return false }
            return commands.contains { hook in
                guard hook["type"] as? String == "command",
                      let command = hook["command"] as? String,
                      command.contains(marker), !disabled.contains(command) else { return false }
                if let name = hook["name"] as? String, disabled.contains(name) { return false }
                return true
            }
        }
    }
}
