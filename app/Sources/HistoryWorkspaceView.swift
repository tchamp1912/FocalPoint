// FocalPoint history workspace — searchable, filterable, grouped SwiftUI UI.

import SwiftUI

struct HistoryWorkspaceView: View {
    @ObservedObject var store: HistoryWorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.records.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .frame(minWidth: 780, minHeight: 540)
        .searchable(text: queryText, placement: .toolbar, prompt: "Search history")
        .toolbar { toolbar }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionPresented,
            titleVisibility: .visible
        ) {
            Button("Delete \(store.pendingDeletion.count) \(runLabel(store.pendingDeletion.count))", role: .destructive) {
                store.confirmDeletion()
            }
            Button("Cancel", role: .cancel) { store.cancelDeletion() }
        } message: {
            Text("This removes the selected local history records. It does not delete project files.")
        }
        .sheet(item: $store.launchDraft) { _ in
            HistoryLaunchSheet(store: store)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("History")
                    .font(.title2.bold())
                Text("Find past work, inspect outcomes, and deliberately start the next run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Group by", selection: $store.grouping) {
                ForEach(HistoryGrouping.allCases) { grouping in
                    Text(grouping.displayName).tag(grouping)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var content: some View {
        VStack(spacing: 0) {
            summaryStrip
            Divider()
            if store.visibleRecords.isEmpty {
                noResults
            } else {
                HSplitView {
                    historyList
                        .frame(minWidth: 480, idealWidth: 580)
                    detailPanel
                        .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
                }
            }
        }
    }

    private var summaryStrip: some View {
        let summary = store.visibleSummary
        return HStack(spacing: 10) {
            summaryItem("Runs", value: summary.runCount.formatted(), symbol: "clock.arrow.circlepath")
            summaryItem("Projects", value: summary.projectCount.formatted(), symbol: "folder")
            summaryItem("Time", value: compactDuration(summary.duration), symbol: "timer")
            summaryItem("Tokens", value: compactNumber(summary.tokens), symbol: "text.word.spacing")
            summaryItem("Est. cost", value: summary.estimatedCostUSD.formatted(.currency(code: "USD")), symbol: "dollarsign.circle")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.025))
    }

    private func summaryItem(_ label: String, value: String, symbol: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.subheadline.bold()).monospacedDigit()
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(store.groups) { group in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                                HistoryRecordRow(
                                    record: record,
                                    isSelected: store.selectedRecordIDs.contains(record.id),
                                    isFocused: store.focusedRecordID == record.id,
                                    onSelect: { store.toggleSelection(record.id) },
                                    onFocus: { store.focusedRecordID = record.id },
                                    onPin: { store.togglePin(record.id) },
                                    onResume: { store.beginLaunch(.resume, recordID: record.id) },
                                    onRerun: { store.beginLaunch(.rerun, recordID: record.id) },
                                    onDelete: { store.requestDeletion([record.id]) }
                                )
                                if index < group.records.count - 1 { Divider().padding(.leading, 45) }
                            }
                        }
                        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.5)))
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .padding(16)
        }
        .background(Color.primary.opacity(0.015))
    }

    private func groupHeader(_ group: HistoryGroup) -> some View {
        HStack(spacing: 7) {
            Image(systemName: group.isPinnedGroup ? "pin.fill" : store.grouping == .project ? "folder.fill" : "point.3.connected.trianglepath.dotted")
                .font(.caption)
                .foregroundStyle(group.isPinnedGroup ? Color.accentColor : Color.secondary)
            Text(group.title).font(.subheadline.bold())
            if let subtitle = group.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(group.records.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .background(.background)
    }

    @ViewBuilder
    private var detailPanel: some View {
        if let record = store.focusedRecord {
            HistoryRecordDetail(
                record: record,
                onPin: { store.togglePin(record.id) },
                onResume: { store.beginLaunch(.resume, recordID: record.id) },
                onRerun: { store.beginLaunch(.rerun, recordID: record.id) },
                onDelete: { store.requestDeletion([record.id]) }
            )
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sidebar.right").font(.title).foregroundStyle(.tertiary)
                Text("Select a run").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No history yet", systemImage: "clock.arrow.circlepath",
            description: Text("Finished sessions and workflows will appear here with their outcome and usage summary.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResults: some View {
        ContentUnavailableView {
            Label("No matching runs", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Try a different search or clear the active filters.")
        } actions: {
            Button("Clear Filters") { store.clearFilters() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                filterSection("Provider", values: HistoryProvider.allCases, selected: providerSelection) { $0.displayName }
                Divider()
                filterSection("State", values: HistoryRunState.allCases, selected: stateSelection) { $0.displayName }
                Divider()
                Menu("Project") {
                    ForEach(store.projects) { project in
                        Toggle(project.name, isOn: projectFilterBinding(project.id))
                    }
                }
                if store.query.isFiltered {
                    Divider()
                    Button("Clear All Filters") { store.clearFilters() }
                }
            } label: {
                Label("Filters", systemImage: store.query.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }

            if store.selectionCount > 0 {
                Button("Delete \(store.selectionCount)", systemImage: "trash", role: .destructive) {
                    store.requestSelectedDeletion()
                }
                Button("Clear Selection") { store.clearSelection() }
            } else {
                Button("Select Visible") { store.selectVisible() }
                    .disabled(store.visibleRecords.isEmpty)
            }
        }
    }

    private func filterSection<Value: Hashable & Identifiable>(
        _ title: String,
        values: [Value],
        selected: (Value) -> Binding<Bool>,
        label: @escaping (Value) -> String
    ) -> some View {
        Menu(title) {
            ForEach(values) { value in
                Toggle(label(value), isOn: selected(value))
            }
        }
    }

    private var providerSelection: (HistoryProvider) -> Binding<Bool> {
        { provider in
            Binding(
                get: { store.query.providers.contains(provider) },
                set: { enabled in
                    if enabled { store.query.providers.insert(provider) }
                    else { store.query.providers.remove(provider) }
                }
            )
        }
    }

    private var stateSelection: (HistoryRunState) -> Binding<Bool> {
        { state in
            Binding(
                get: { store.query.states.contains(state) },
                set: { enabled in
                    if enabled { store.query.states.insert(state) }
                    else { store.query.states.remove(state) }
                }
            )
        }
    }

    private func projectFilterBinding(_ projectID: String) -> Binding<Bool> {
        Binding(
            get: { store.query.projectIDs.contains(projectID) },
            set: { enabled in
                if enabled { store.query.projectIDs.insert(projectID) }
                else { store.query.projectIDs.remove(projectID) }
            }
        )
    }

    private var queryText: Binding<String> {
        Binding(get: { store.query.text }, set: { store.query.text = $0 })
    }

    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { !store.pendingDeletion.isEmpty },
            set: { if !$0 { store.cancelDeletion() } }
        )
    }

    private var deletionTitle: String {
        "Delete \(store.pendingDeletion.count) \(runLabel(store.pendingDeletion.count))?"
    }
}

private struct HistoryRecordRow: View {
    let record: HistoryRecord
    let isSelected: Bool
    let isFocused: Bool
    let onSelect: () -> Void
    let onFocus: () -> Void
    let onPin: () -> Void
    let onResume: () -> Void
    let onRerun: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Remove from selection" : "Add to selection")

            Button(action: onFocus) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: record.state.symbolName)
                            .foregroundStyle(stateColor(record.state))
                        Text(record.title).font(.body.weight(.medium)).lineLimit(1)
                        if record.isPinned {
                            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(record.endedAt, style: .relative)
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Text(record.summary)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack(spacing: 6) {
                        HistoryTag(text: record.provider.displayName, symbol: record.provider.symbolName)
                        HistoryTag(text: record.model, symbol: "cpu")
                        HistoryTag(text: compactDuration(record.duration), symbol: "timer")
                        HistoryTag(text: compactNumber(record.usage.totalTokens), symbol: "text.word.spacing")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(record.isPinned ? "Unpin" : "Pin", action: onPin)
                Divider()
                Button("Resume", action: onResume).disabled(!record.isResumeEligible)
                Button("Rerun", action: onRerun).disabled(!record.isRerunEligible)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(12)
        .background(isFocused ? Color.accentColor.opacity(0.09) : .clear)
    }
}

private struct HistoryRecordDetail: View {
    let record: HistoryRecord
    let onPin: () -> Void
    let onResume: () -> Void
    let onRerun: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: record.state.symbolName).foregroundStyle(stateColor(record.state))
                        Text(record.state.displayName).font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: onPin) {
                            Image(systemName: record.isPinned ? "pin.slash" : "pin")
                        }
                        .buttonStyle(.borderless)
                        .help(record.isPinned ? "Unpin" : "Pin")
                    }
                    Text(record.title).font(.title3.bold())
                    Text(record.summary).font(.subheadline).foregroundStyle(.secondary)
                }

                detailSection("Context") {
                    detailLine("Project", record.project.name)
                    detailLine("Workflow", record.workflow?.name ?? "One-off")
                    detailLine("Provider", record.provider.displayName)
                    detailLine("Model", record.model)
                }
                detailSection("Run summary") {
                    detailLine("Duration", compactDuration(record.duration))
                    detailLine("Tokens", compactNumber(record.usage.totalTokens))
                    detailLine("Tool calls", record.usage.toolCalls.formatted())
                    if let cost = record.usage.estimatedCostUSD {
                        detailLine("Estimated cost", cost.formatted(.currency(code: "USD")))
                    }
                }

                VStack(spacing: 9) {
                    Button(action: onResume) {
                        Label("Resume conversation", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!record.isResumeEligible)
                    eligibilityNote(
                        eligible: record.isResumeEligible,
                        eligibleText: "Choose a project, provider, and model before resuming.",
                        unavailableText: "Resume unavailable: this provider has no resumable conversation."
                    )

                    Button(action: onRerun) {
                        Label("Rerun task", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!record.isRerunEligible)
                    eligibilityNote(
                        eligible: record.isRerunEligible,
                        eligibleText: "Starts a new run from the saved task after explicit setup.",
                        unavailableText: "Rerun unavailable: no source task was retained."
                    )
                }

                Divider()
                Button("Delete this record", role: .destructive, action: onDelete)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
        }
    }

    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.tertiary)
            content()
        }
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
        .font(.caption)
    }

    private func eligibilityNote(eligible: Bool, eligibleText: String, unavailableText: String) -> some View {
        Text(eligible ? eligibleText : unavailableText)
            .font(.caption2)
            .foregroundStyle(eligible ? Color.secondary : Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HistoryLaunchSheet: View {
    @ObservedObject var store: HistoryWorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(draft?.mode.displayName ?? "Launch") “\(draft?.record.title ?? "Run")”")
                    .font(.title3.bold())
                Text("Choose every launch setting. FocalPoint will not reuse the record’s provider or model automatically.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            Form {
                Picker("Project", selection: projectBinding) {
                    Text("Choose a project…").tag(String?.none)
                    ForEach(store.projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                Picker("Provider", selection: providerBinding) {
                    Text("Choose a provider…").tag(HistoryProvider?.none)
                    ForEach(availableProviders) { provider in
                        Text(provider.displayName).tag(Optional(provider))
                    }
                }
                Picker("Model", selection: modelBinding) {
                    Text(providerBinding.wrappedValue == nil ? "Choose a provider first…" : "Choose a model…")
                        .tag(String?.none)
                    ForEach(modelsForProvider, id: \.self) { model in
                        Text(model).tag(Optional(model))
                    }
                }
                .disabled(providerBinding.wrappedValue == nil)
            }
            .formStyle(.grouped)

            HStack {
                Text("All three choices are required.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { store.cancelLaunch() }
                    .keyboardShortcut(.cancelAction)
                Button(draft?.mode.displayName ?? "Launch") { store.submitLaunch() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft?.isComplete != true)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var draft: HistoryLaunchDraft? { store.launchDraft }

    private var availableProviders: [HistoryProvider] {
        if draft?.mode == .resume, let provider = draft?.record.provider {
            return [provider]
        }
        return Array(Set(store.launchOptions.map(\.provider)))
            .sorted { $0.rawValue < $1.rawValue }
    }

    private var modelsForProvider: [String] {
        guard let provider = draft?.provider else { return [] }
        return store.launchOptions.filter { $0.provider == provider }.map(\.model).sorted()
    }

    private var projectBinding: Binding<String?> {
        Binding(
            get: { store.launchDraft?.project?.id },
            set: { id in store.launchDraft?.project = store.projects.first { $0.id == id } }
        )
    }

    private var providerBinding: Binding<HistoryProvider?> {
        Binding(
            get: { store.launchDraft?.provider },
            set: { provider in
                store.launchDraft?.provider = provider
                store.launchDraft?.model = nil
            }
        )
    }

    private var modelBinding: Binding<String?> {
        Binding(get: { store.launchDraft?.model }, set: { store.launchDraft?.model = $0 })
    }
}

private struct HistoryTag: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.09), in: Capsule())
    }
}

private func stateColor(_ state: HistoryRunState) -> Color {
    switch state {
    case .completed: return .green
    case .failed: return .red
    case .cancelled: return .secondary
    case .interrupted: return .orange
    }
}

private func compactDuration(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds) / 60)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    let remainder = minutes % 60
    return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
}

private func compactNumber(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
    if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
    return value.formatted()
}

private func runLabel(_ count: Int) -> String { count == 1 ? "run" : "runs" }
