import SwiftUI

struct ScheduledPromptsView: View {
    @ObservedObject var model: AppModel
    let onNew: () -> Void
    let onEdit: (ScheduledPrompt) -> Void
    @State private var busyID: String?
    @State private var actionError: String?
    @State private var deleting: ScheduledPrompt?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Schedules").font(.title2.bold())
                    Text("Reusable prompts, launched automatically on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.refreshSchedules() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("Refresh schedules").accessibilityLabel("Refresh schedules")
                    .disabled(model.schedulesLoading || !model.connected)
                Button("New schedule", action: onNew).buttonStyle(.borderedProminent)
            }.padding(20)
            Divider()
            if !model.connected {
                Label("The daemon is offline. Schedules resume when it reconnects.", systemImage: "bolt.slash")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
            if let error = actionError ?? model.scheduleError {
                Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
            }
            if model.schedulesLoading && model.scheduledPrompts.isEmpty {
                Spacer(); ProgressView("Loading schedules…"); Spacer()
            } else if model.scheduledPrompts.isEmpty {
                ContentUnavailableView("No schedules yet", systemImage: "calendar.badge.clock",
                                       description: Text("Save a prompt, choose its agent and folder, then set when it runs."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.scheduledPrompts) { schedule in scheduleCard(schedule) }
                    }.padding(20)
                }
            }
            Divider()
            Text("The Mac must be awake and the daemon running. Missed times combine into one run after downtime. A previous run that is still active skips the next occurrence.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            while !Task.isCancelled {
                if model.connected { await model.refreshSchedules() }
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { break }
            }
        }
        .onChange(of: model.connected) { _, up in if up { Task { await model.refreshSchedules() } } }
        .alert("Delete schedule?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                guard let schedule = deleting else { return }
                deleting = nil
                perform(schedule) { await model.deleteSchedule(schedule) }
            }
        } message: {
            Text("Delete \(deleting?.name ?? "this schedule")? This removes future runs; an active session keeps running.")
        }
    }

    private func scheduleCard(_ schedule: ScheduledPrompt) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(schedule.name).font(.headline)
                    Text("\(schedule.launch.provider.displayName) · \(schedule.launch.model)")
                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(schedule.enabled ? "Enabled" : "Paused")
                    .font(.caption.weight(.medium)).foregroundStyle(schedule.enabled ? .green : .secondary)
                if busyID == schedule.id { ProgressView().controlSize(.small) }
            }
            Label(schedule.launch.cwd, systemImage: "folder")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack(spacing: 16) {
                Label("\(schedule.cron) · \(schedule.timezone)", systemImage: "calendar")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Text(nextRun(schedule)).font(.caption).foregroundStyle(.secondary)
            }
            if let run = schedule.latestRun {
                Text("Last attempt: \(run.status.capitalized) · \(date(run.attemptedAt))")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = run.error, !error.isEmpty {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
            } else { Text("No runs yet").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Prompt") {
                Text(schedule.launch.task).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            if schedule.lastRuns.count > 1 {
                DisclosureGroup("Recent attempts") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(schedule.lastRuns.sorted { $0.attemptedAt > $1.attemptedAt }.prefix(5)) { run in
                            Text("\(date(run.attemptedAt)) · \(run.status)\(run.error.map { " · " + $0 } ?? "")")
                                .font(.caption).textSelection(.enabled)
                        }
                    }.padding(.top, 6)
                }
            }
            HStack {
                Button("Edit…") { onEdit(schedule) }
                Button(schedule.enabled ? "Pause" : "Resume") {
                    perform(schedule) { await model.setScheduleEnabled(schedule, enabled: !schedule.enabled) }
                }
                Spacer()
                Button("Delete…", role: .destructive) { deleting = schedule }
            }.disabled(busyID != nil || !model.connected)
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.09)))
    }

    private func nextRun(_ schedule: ScheduledPrompt) -> String {
        guard schedule.enabled else { return "Paused" }
        guard let next = schedule.nextRunAt else { return "Next run unavailable" }
        return "Next: \(date(next, timezone: schedule.timezone))"
    }
    private func date(_ seconds: Double, timezone: String = "local") -> String {
        let value = Date(timeIntervalSince1970: seconds)
        let zone = timezone == "UTC" ? TimeZone(secondsFromGMT: 0)! : TimeZone.current
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.timeZone = zone
        return formatter.string(from: value) + " " + (timezone == "UTC" ? "UTC" : zone.abbreviation(for: value) ?? "local")
    }
    private func perform(_ schedule: ScheduledPrompt, action: @escaping () async -> String?) {
        guard busyID == nil else { return }
        busyID = schedule.id; actionError = nil
        Task { @MainActor in actionError = await action(); busyID = nil }
    }
}
