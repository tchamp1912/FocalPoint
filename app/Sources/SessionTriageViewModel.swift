// FocalPoint menu-bar app — observable state for the session triage surface.
// MIT License.

import SwiftUI
import Combine

@MainActor
final class SessionTriageViewModel: ObservableObject {
    typealias SessionAction = (SessionTriageSession) -> Void

    @Published var sessions: [SessionTriageSession]
    @Published var searchText = "" { didSet { debounceSearch() } }
    @Published private(set) var debouncedSearchText = ""
    @Published var filters = SessionTriageFilters()
    @Published var sort: SessionTriageSort = .attention
    @Published var grouping: SessionTriageGrouping = .manager

    let onFocus: SessionAction
    let onStop: SessionAction
    private let debounceNanoseconds: UInt64
    private var searchTask: Task<Void, Never>?

    init(
        sessions: [SessionTriageSession],
        debounceMilliseconds: UInt64 = 250,
        onFocus: @escaping SessionAction,
        onStop: @escaping SessionAction
    ) {
        self.sessions = sessions
        self.debounceNanoseconds = debounceMilliseconds * 1_000_000
        self.onFocus = onFocus
        self.onStop = onStop
    }

    convenience init(
        sessions: [SessionInfo],
        workflow: (SessionInfo) -> String = { _ in "Independent" },
        onFocus: @escaping SessionAction,
        onStop: @escaping SessionAction
    ) {
        self.init(sessions: sessions.map { SessionTriageSession(session: $0, workflow: workflow($0)) },
                  onFocus: onFocus, onStop: onStop)
    }

    deinit { searchTask?.cancel() }

    var options: SessionTriageFilterOptions { SessionTriageEngine.options(for: sessions) }
    var attentionCount: Int { sessions.filter(\.needsAttention).count }
    var filteredSessions: [SessionTriageSession] {
        SessionTriageEngine.sort(
            SessionTriageEngine.filter(sessions, search: debouncedSearchText, filters: filters),
            by: sort
        )
    }
    var groups: [SessionTriageGroup] {
        SessionTriageEngine.group(filteredSessions, by: grouping, managerDirectory: sessions)
    }
    var hasQuery: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasActiveFilters: Bool { filters.activeDimensionCount > 0 }

    func clearSearchAndFilters() {
        searchTask?.cancel()
        searchText = ""
        debouncedSearchText = ""
        filters.clear()
    }

    private func debounceSearch() {
        searchTask?.cancel()
        let pending = searchText
        let delay = debounceNanoseconds
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.debouncedSearchText = pending
        }
    }
}
