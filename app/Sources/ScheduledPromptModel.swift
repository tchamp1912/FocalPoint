// FocalPoint — persistent scheduled prompt transport and form rules.
import Foundation

struct ScheduledPromptLaunch: Codable, Equatable {
    var provider: ManagedQuickLaunchProvider
    var agentType: String
    var model: String
    var cwd: String
    var task: String
    var title: String
    var customLauncher: String?
    var terminalColor: String?
    var cursorMode: String?

    enum CodingKeys: String, CodingKey {
        case provider, model, cwd, task, title
        case agentType = "agent_type", customLauncher = "custom_launcher"
        case terminalColor = "terminal_color", cursorMode = "cursor_mode"
    }

    init(request: ManagedQuickLaunchRequest) {
        provider = request.provider; agentType = request.agentType; model = request.model
        cwd = request.cwd; task = request.task; title = request.title
        customLauncher = request.customLauncher; terminalColor = request.terminalColor
    }

    var draft: ManagedQuickLaunchDraft {
        // The saved task already contains any persona. Do not add it twice.
        .init(task: task, cwd: cwd, agentType: "", provider: provider, model: model,
              title: title, terminalColor: terminalColor, customLauncher: customLauncher)
    }
}

struct ScheduledPromptRun: Codable, Equatable, Identifiable {
    var taskID: String
    var scheduledAt: Double
    var attemptedAt: Double
    var status: String
    var error: String?
    var id: String { "\(taskID)-\(attemptedAt)" }
    enum CodingKeys: String, CodingKey {
        case taskID = "task_id", scheduledAt = "scheduled_at", attemptedAt = "attempted_at"
        case status, error
    }
}

struct ScheduledPrompt: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var cron: String
    var timezone: String
    var enabled: Bool
    var launch: ScheduledPromptLaunch
    var nextRunAt: Double?
    var activeTaskID: String?
    var lastRuns: [ScheduledPromptRun] = []

    enum CodingKeys: String, CodingKey {
        case id, name, cron, timezone, enabled, launch
        case nextRunAt = "next_run_at", activeTaskID = "active_task_id", lastRuns = "last_runs"
    }

    var latestRun: ScheduledPromptRun? { lastRuns.max { $0.attemptedAt < $1.attemptedAt } }
    var savePayload: [String: Any] {
        // Execution history belongs to the daemon. Never submit it on edits.
        let launchObject = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(launch))) as? [String: Any] ?? [:]
        return ["cmd": "schedule-save", "schedule": ["id": id, "name": name, "cron": cron,
                "timezone": timezone, "enabled": enabled, "launch": launchObject]]
    }
}

enum ScheduledPromptCadence: String, CaseIterable, Identifiable {
    case hourly, daily, weekdays, weekly, custom
    var id: String { rawValue }
    var label: String { self == .custom ? "Custom cron" : rawValue.capitalized }
}

struct ScheduledPromptDraft: Equatable {
    var id = "schedule-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(23)
    var name = ""
    var cadence: ScheduledPromptCadence = .daily
    var hour = 9
    var minute = 0
    var weekday = 1
    var customCron = "0 9 * * *"
    var timezone = "local"
    var enabled = true

    var cron: String {
        switch cadence {
        case .hourly: return "\(minute) * * * *"
        case .daily: return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * 1-5"
        case .weekly: return "\(minute) \(hour) * * \(weekday)"
        case .custom: return customCron.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    init() {}
    init(schedule: ScheduledPrompt) {
        id = schedule.id; name = schedule.name; customCron = schedule.cron
        timezone = schedule.timezone; enabled = schedule.enabled; cadence = .custom
    }

    var validationError: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.utf8.count > 256 || trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            return "Give this schedule a name of 1–256 bytes of printable text."
        }
        if cron.split(whereSeparator: \.isWhitespace).count != 5 {
            return "Use five cron fields: minute hour day-of-month month weekday."
        }
        return nil // The daemon is authoritative for cron ranges and next occurrence.
    }

    func schedule(request: ManagedQuickLaunchRequest, existing: ScheduledPrompt? = nil,
                  preserveAgentType: Bool = false) -> ScheduledPrompt {
        var launch = ScheduledPromptLaunch(request: request)
        if let existing {
            if preserveAgentType { launch.agentType = existing.launch.agentType }
            if request.provider == .cursor { launch.cursorMode = existing.launch.cursorMode }
        }
        return .init(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), cron: cron,
                     timezone: timezone, enabled: enabled, launch: launch)
    }
}

enum ScheduledPromptResponse {
    static func error(_ response: [String: Any]?) -> String? {
        guard let response else { return "Could not reach the FocalPoint daemon. Reconnect and try again." }
        guard response["ok"] as? Bool != true else { return nil }
        let message = response["error"] as? String ?? "The daemon did not accept the schedule request."
        let lower = message.lowercased()
        if lower.contains("unknown") && (lower.contains("command") || lower.contains("cmd")
            || (lower.contains("variant") && lower.contains("schedule-"))) {
            return "This daemon does not support schedules. Update FocalPoint and restart its daemon, then try again."
        }
        return message
    }
}
