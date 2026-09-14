import Foundation

@main
enum ScheduledPromptTests {
    static func main() throws {
        var draft = ScheduledPromptDraft()
        precondition(draft.id.utf8.count <= 32)
        precondition(draft.id != ScheduledPromptDraft().id)
        precondition(draft.validationError != nil)
        draft.name = " Daily review "
        precondition(draft.cron == "0 9 * * *")
        precondition(draft.validationError == nil)
        draft.minute = 15
        draft.hour = 18
        draft.cadence = .hourly
        precondition(draft.cron == "15 * * * *")
        draft.cadence = .weekdays
        precondition(draft.cron == "15 18 * * 1-5")
        draft.cadence = .weekly
        draft.weekday = 0
        precondition(draft.cron == "15 18 * * 0")
        draft.cadence = .custom
        draft.customCron = "  */20 9-17 * * 1-5\n"
        precondition(draft.cron == "*/20 9-17 * * 1-5")
        precondition(draft.validationError == nil)
        draft.customCron = "0 9 * *"
        precondition(draft.validationError != nil)
        draft.customCron = "0 9 * * *"
        draft.timezone = "UTC"

        let baked = "Agent instructions:\nReview carefully.\n\nTask:\nCheck the project and report findings."
        let request = ManagedQuickLaunchRequest(task: baked, cwd: "/tmp", agentType: "reviewer",
            provider: .claude, model: "gateway-model", title: "Daily review", taskID: "not-reused",
            complexity: .standard, terminalColor: "#60A5FA", customLauncher: "/tmp/custom-launcher")
        var schedule = draft.schedule(request: request)
        precondition(schedule.name == "Daily review")
        let payload = schedule.savePayload
        precondition(payload["cmd"] as? String == "schedule-save")
        let spec = payload["schedule"] as! [String: Any]
        precondition(spec["id"] as? String == draft.id)
        precondition(spec["next_run_at"] == nil && spec["last_runs"] == nil)
        let launch = spec["launch"] as! [String: Any]
        precondition(launch["provider"] as? String == "claude")
        precondition(launch["task"] as? String == baked)
        precondition(launch["model"] as? String == "gateway-model")
        precondition(launch["custom_launcher"] as? String == "/tmp/custom-launcher")
        precondition(launch["terminal_color"] as? String == "#60A5FA")
        precondition(launch["task_id"] == nil && launch["cmd"] == nil && launch["role"] == nil,
                     "Each occurrence must receive a fresh daemon-owned task identity")

        schedule.enabled = false
        let editor = ScheduledPromptDraft(schedule: schedule)
        precondition(editor.id == schedule.id && !editor.enabled && editor.timezone == "UTC")
        precondition(editor.cron == schedule.cron)
        let launchDraft = schedule.launch.draft
        precondition(launchDraft.agentType.isEmpty && launchDraft.task == baked,
                     "Editing a baked prompt must not reapply an installed persona")
        precondition(launchDraft.model == request.model && launchDraft.customLauncher == request.customLauncher)
        let validated = try ManagedQuickLaunchRules.request(from: {
            var direct = launchDraft; direct.agentType = "direct"; return direct
        }(), directoryExists: { _ in true }, launcherExists: { _ in true }).get()
        let edited = editor.schedule(request: validated, existing: schedule, preserveAgentType: true)
        precondition(edited.launch.task == baked && edited.launch.agentType == "reviewer")
        precondition(edited.id == schedule.id && !edited.enabled)

        let responseJSON = """
        {"id":"review","name":"Review","cron":"0 9 * * *","timezone":"local","enabled":true,
         "launch":{"provider":"codex","agent_type":"direct","model":"gpt-6-astra","cwd":"/tmp","task":"Review","title":"Review"},
         "next_run_at":2000,"active_task_id":null,"last_runs":[
           {"task_id":"old","scheduled_at":1000,"attempted_at":1001,"status":"launched","error":null,"finished_at":1002},
           {"task_id":"new","scheduled_at":1500,"attempted_at":1501,"status":"error","error":"CLI unavailable"}]}
        """
        let decoded = try JSONDecoder().decode(ScheduledPrompt.self, from: Data(responseJSON.utf8))
        precondition(decoded.nextRunAt == 2000 && decoded.activeTaskID == nil)
        precondition(decoded.latestRun?.taskID == "new" && decoded.latestRun?.error == "CLI unavailable")
        precondition(decoded.launch.draft.model == "gpt-6-astra")
        precondition(ScheduledPromptResponse.error(["ok": true]) == nil)
        precondition(ScheduledPromptResponse.error(["ok": false, "error": "unknown command: schedule-list"])!.contains("Update FocalPoint"))
        precondition(ScheduledPromptResponse.error(["ok": false, "error": "invalid request: unknown variant `schedule-save`, expected `launch-session` at line 1 column 22"])!.contains("Update FocalPoint"))
        precondition(ScheduledPromptResponse.error(["ok": false, "error": "Invalid cron range"]) == "Invalid cron range")
        precondition(ScheduledPromptResponse.error(nil)!.contains("Reconnect"))
        print("Scheduled prompt tests passed")
    }
}
