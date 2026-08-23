// FocalPoint history workspace — observable state and deterministic actions.

import Foundation
import SwiftUI

@MainActor
final class HistoryWorkspaceStore: ObservableObject {
    @Published private(set) var records: [HistoryRecord]
    @Published var query = HistoryQuery()
    @Published var grouping: HistoryGrouping = .project
    @Published var selectedRecordIDs: Set<String> = []
    @Published var focusedRecordID: String?
    @Published private(set) var pendingDeletion: Set<String> = []
    @Published var launchDraft: HistoryLaunchDraft?

    let projects: [HistoryProject]
    let launchOptions: [HistoryLaunchOption]
    private let actionHandler: (HistoryWorkspaceAction) -> Void

    init(
        records: [HistoryRecord],
        projects: [HistoryProject]? = nil,
        launchOptions: [HistoryLaunchOption] = [],
        actionHandler: @escaping (HistoryWorkspaceAction) -> Void = { _ in }
    ) {
        self.records = records
        self.projects = projects ?? Self.distinctProjects(in: records)
        self.launchOptions = launchOptions
        self.actionHandler = actionHandler
        self.focusedRecordID = records.sorted { $0.endedAt > $1.endedAt }.first?.id
    }

    convenience init(sampleData: Bool = true) {
        self.init(
            records: sampleData ? HistoryWorkspaceSamples.records : [],
            projects: sampleData ? HistoryWorkspaceSamples.projects : [],
            launchOptions: sampleData ? HistoryWorkspaceSamples.launchOptions : []
        )
    }

    var visibleRecords: [HistoryRecord] {
        HistoryWorkspaceQuery.filter(records, by: query)
    }

    var groups: [HistoryGroup] {
        HistoryWorkspaceQuery.groups(for: visibleRecords, grouping: grouping)
    }

    var visibleSummary: HistoryCollectionSummary {
        HistoryWorkspaceQuery.summary(for: visibleRecords)
    }

    var focusedRecord: HistoryRecord? {
        guard let focusedRecordID else { return nil }
        return records.first { $0.id == focusedRecordID }
    }

    var selectionCount: Int { selectedRecordIDs.count }

    func toggleSelection(_ id: String) {
        if selectedRecordIDs.contains(id) {
            selectedRecordIDs.remove(id)
        } else {
            selectedRecordIDs.insert(id)
        }
        focusedRecordID = id
    }

    func selectVisible() {
        selectedRecordIDs.formUnion(visibleRecords.map(\.id))
    }

    func clearSelection() {
        selectedRecordIDs.removeAll()
    }

    func togglePin(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isPinned.toggle()
        actionHandler(.pin(recordID: id, isPinned: records[index].isPinned))
    }

    func requestDeletion(_ ids: Set<String>) {
        pendingDeletion = ids.intersection(Set(records.map(\.id)))
    }

    func requestSelectedDeletion() {
        requestDeletion(selectedRecordIDs)
    }

    func cancelDeletion() {
        pendingDeletion.removeAll()
    }

    func confirmDeletion() {
        guard !pendingDeletion.isEmpty else { return }
        let deleted = pendingDeletion
        records.removeAll { deleted.contains($0.id) }
        selectedRecordIDs.subtract(deleted)
        if let focusedRecordID, deleted.contains(focusedRecordID) {
            self.focusedRecordID = visibleRecords.first?.id
        }
        pendingDeletion.removeAll()
        actionHandler(.delete(recordIDs: deleted))
    }

    func beginLaunch(_ mode: HistoryLaunchMode, recordID: String) {
        guard let record = records.first(where: { $0.id == recordID }) else { return }
        let eligible = mode == .resume ? record.isResumeEligible : record.isRerunEligible
        guard eligible else { return }

        // Intentionally do not initialize any choice from the source record or
        // a previous launch. Every launch requires fresh, explicit intent.
        launchDraft = HistoryLaunchDraft(record: record, mode: mode)
    }

    func cancelLaunch() {
        launchDraft = nil
    }

    func submitLaunch() {
        guard let draft = launchDraft,
              let request = draft.request()
        else { return }
        actionHandler(.launch(request))
        launchDraft = nil
    }

    func clearFilters() {
        query = HistoryQuery()
    }

    func pruneSelectionToVisibleRecords() {
        selectedRecordIDs.formIntersection(Set(visibleRecords.map(\.id)))
    }

    /// Replaces only daemon/app-owned records while preserving the workspace
    /// controls a human has already set in this window.
    func replaceRecords(_ records: [HistoryRecord]) {
        self.records = records
        selectedRecordIDs.formIntersection(Set(records.map(\.id)))
        if let focusedRecordID, !records.contains(where: { $0.id == focusedRecordID }) {
            self.focusedRecordID = records.sorted { $0.endedAt > $1.endedAt }.first?.id
        }
    }

    private static func distinctProjects(in records: [HistoryRecord]) -> [HistoryProject] {
        var seen = Set<String>()
        return records
            .map(\.project)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct HistoryLaunchDraft: Identifiable {
    let record: HistoryRecord
    let mode: HistoryLaunchMode
    var project: HistoryProject?
    var provider: HistoryProvider?
    var model: String?

    var id: String { "\(mode.rawValue):\(record.id)" }

    var isComplete: Bool {
        project != nil && provider != nil
            && (mode != .resume || provider == record.provider)
            && model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func request() -> HistoryLaunchRequest? {
        guard let project, let provider,
              mode != .resume || provider == record.provider,
              let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return nil }
        return HistoryLaunchRequest(
            sourceRecordID: record.id, mode: mode, project: project,
            provider: provider, model: model,
            resumeToken: mode == .resume ? record.resumeToken : nil,
            sourcePrompt: mode == .rerun ? record.sourcePrompt : nil
        )
    }
}
