import Foundation

@MainActor
extension AppModel {
    func refreshSchedules() async {
        scheduleRefreshGeneration &+= 1
        let generation = scheduleRefreshGeneration
        schedulesLoading = true
        let response = await requestSchedule(["cmd": "schedule-list"])
        // A save must refresh even when a polling request is in flight. The
        // older response cannot replace the list after that newer refresh.
        guard generation == scheduleRefreshGeneration else { return }
        defer { schedulesLoading = false }
        if let error = ScheduledPromptResponse.error(response) { scheduleError = error; return }
        guard let rows = response?["schedules"] as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: rows),
              let schedules = try? JSONDecoder().decode([ScheduledPrompt].self, from: data) else {
            scheduleError = "The daemon returned an unreadable schedule list. Update the app and daemon together."
            return
        }
        scheduledPrompts = schedules.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        scheduleError = nil
    }

    func saveSchedule(_ schedule: ScheduledPrompt) async -> String? {
        let response = await requestSchedule(schedule.savePayload)
        if let error = ScheduledPromptResponse.error(response) { return error }
        await refreshSchedules()
        return nil
    }

    func setScheduleEnabled(_ schedule: ScheduledPrompt, enabled: Bool) async -> String? {
        let response = await requestSchedule(["cmd": "schedule-set-enabled", "id": schedule.id, "enabled": enabled])
        if let error = ScheduledPromptResponse.error(response) { return error }
        await refreshSchedules()
        return nil
    }

    func deleteSchedule(_ schedule: ScheduledPrompt) async -> String? {
        let response = await requestSchedule(["cmd": "schedule-delete", "id": schedule.id])
        if let error = ScheduledPromptResponse.error(response) { return error }
        await refreshSchedules()
        return nil
    }

    private func requestSchedule(_ payload: [String: Any]) async -> [String: Any]? {
        let client = self.client
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: client.scheduleRequest(payload))
            }
        }
    }
}
