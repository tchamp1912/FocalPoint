// FocalPoint menu-bar app — scalable search, filtering, and action surface.
// MIT License.

import SwiftUI

struct SessionTriageView: View {
    @ObservedObject var model: SessionTriageViewModel
    var onColorChange: ((SessionTriageSession, String) -> Void)? = nil
    @State private var pendingStop: SessionTriageSession?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            content
        }
        .frame(minWidth: 680, minHeight: 460)
        .alert("Stop this session?", isPresented: stopConfirmationPresented, presenting: pendingStop) { session in
            Button("Cancel", role: .cancel) { pendingStop = nil }
            Button("Stop Session", role: .destructive) {
                model.onStop(session)
                pendingStop = nil
            }
        } message: { session in
            Text("“\(session.title)” will be asked to stop. Unsaved agent work may be interrupted. This cannot be undone from FocalPoint.")
        }
    }

    private var stopConfirmationPresented: Binding<Bool> {
        Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } })
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Live Sessions").font(.title2.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if model.attentionCount > 0 {
                Label("\(model.attentionCount) need attention", systemImage: "bell.badge.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .liquidGlass(.chip, radius: Metrics.badgeRadius, tint: .orange.opacity(0.15))
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var summary: String {
        let shown = model.filteredSessions.count
        return shown == model.sessions.count
            ? "\(shown) \(shown == 1 ? "session" : "sessions")"
            : "Showing \(shown) of \(model.sessions.count) sessions"
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search name, project, workflow, provider, or task ID", text: $model.searchText)
                        .textFieldStyle(.plain)
                    if !model.searchText.isEmpty {
                        Button { model.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain).help("Clear search")
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .liquidGlass(.chip, radius: Metrics.rowRadius)

                Toggle(isOn: attentionBinding) {
                    Label("Attention only", systemImage: "bell")
                }
                .toggleStyle(.button)
                .help("Show waiting, approval, error, and disconnected sessions")

                Menu {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(SessionTriageSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Label(model.sort.title, systemImage: "arrow.up.arrow.down") }
                .menuStyle(.borderlessButton).fixedSize()

                Menu {
                    Picker("Group", selection: $model.grouping) {
                        ForEach(SessionTriageGrouping.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Label(model.grouping.title, systemImage: "rectangle.3.group") }
                .menuStyle(.borderlessButton).fixedSize()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    stringFilter(title: "Project", symbol: "folder", options: model.options.projects, selection: projectsBinding)
                    stringFilter(title: "Provider", symbol: "cpu", options: model.options.providers, selection: providersBinding)
                    stringFilter(title: "Workflow", symbol: "point.3.connected.trianglepath.dotted", options: model.options.workflows, selection: workflowsBinding)
                    stateFilter
                    managedFilter
                    if model.hasActiveFilters {
                        Button("Clear filters") { model.filters.clear() }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
    }

    private var content: some View {
        Group {
            if model.sessions.isEmpty {
                emptyState(symbol: "rectangle.stack", title: "No live sessions",
                           detail: "Sessions will appear here when an agent connects.", action: nil)
            } else if model.filteredSessions.isEmpty {
                emptyState(symbol: "line.3.horizontal.decrease.circle", title: "No matching sessions",
                           detail: "Try a broader search or remove one of the active filters.",
                           action: ("Clear search and filters", model.clearSearchAndFilters))
            } else {
                ScrollView {
                    LazyVStack(spacing: 14, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.groups) { group in
                            Section {
                                VStack(spacing: 6) {
                                    ForEach(group.sessions) { session in row(session) }
                                }
                            } header: {
                                groupHeader(group)
                            }
                        }
                    }
                    .padding(18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupHeader(_ group: SessionTriageGroup) -> some View {
        HStack(spacing: 7) {
            Text(group.title).font(.headline)
            Text("\(group.sessions.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if group.attentionCount > 0 {
                Text("\(group.attentionCount) attention").font(.caption2.weight(.medium)).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(.vertical, 5)
        // Pinned header: a toolbar-style material occludes rows scrolling
        // under it and blends with whatever pane hosts the view (the
        // unified window's detail pane is glass, not an opaque window).
        .background(.bar)
    }

    private func row(_ session: SessionTriageSession) -> some View {
        HStack(spacing: 11) {
            slotBadge(session.slot)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(session.title).font(.body.weight(.medium)).lineLimit(1)
                    if session.isManager {
                        Text("Manager").triageBadge(color: .purple)
                    }
                }
                HStack(spacing: 6) {
                    Text(session.provider.capitalized)
                    if session.project != "No project" && model.grouping != .project {
                        Text("·")
                        Text(session.project)
                    }
                    if session.workflow != "Independent" && model.grouping != .workflow {
                        Text("·")
                        Text(session.workflow)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 5) {
                HStack(spacing: 5) {
                    if session.isConnected {
                        StateSwatch(state: session.state, color: defaultStyle(session.state).color, size: 8)
                    } else {
                        Image(systemName: "bolt.slash").foregroundStyle(.secondary)
                    }
                    Text(session.isConnected ? session.state.display : "Disconnected")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.primary.opacity(0.05), in: Capsule())
                Text(session.updatedAt, style: .relative)
                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    .help("Last state change")
            }
            Button { model.onFocus(session) } label: {
                Label("Focus", systemImage: "scope")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!session.isConnected)
            .help(session.isConnected ? "Focus \(session.title)" : "This session is disconnected; its window is no longer available.")
            Menu {
                if session.isManaged && session.isConnected, let onColorChange {
                    ManagedTerminalColorMenu { color in onColorChange(session, color) }
                    Divider()
                }
                Text(session.isManaged ? "Managed session" : "External session")
                if let taskID = session.stableTaskID { Text("Task: \(taskID)") }
                Divider()
                Button("Stop Session…", role: .destructive) { pendingStop = session }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .frame(width: 24)
            .help("More actions for \(session.title)")
            .accessibilityLabel("More actions for \(session.title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .liquidGlass(.card, radius: Metrics.rowRadius,
                     tint: session.needsAttention ? .orange.opacity(0.08) : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(session.title), slot \(session.slot.map(String.init) ?? "none"), \(session.isConnected ? session.state.display : "Disconnected")")
    }

    private func slotBadge(_ slot: Int?) -> some View {
        Text(slot.map(String.init) ?? "—")
            .font(.system(.caption, design: .rounded).weight(.bold))
            .monospacedDigit().frame(width: 24, height: 24)
            .liquidGlass(.chip, radius: 6)
            .help(slot.map { "Stable keyboard slot \($0)" } ?? "No keyboard slot")
    }

    private func emptyState(symbol: String, title: String, detail: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let action { Button(action.0, action: action.1).buttonStyle(.borderedProminent) }
        }
        .frame(maxWidth: 360).padding(30)
    }

    private func stringFilter(title: String, symbol: String, options: [String], selection: Binding<Set<String>>) -> some View {
        Menu {
            if options.isEmpty { Text("No options") }
            ForEach(options, id: \.self) { value in
                Button { selection.wrappedValue.toggle(value) } label: {
                    Label(value, systemImage: selection.wrappedValue.contains(value) ? "checkmark" : "")
                }
            }
            if !selection.wrappedValue.isEmpty {
                Divider()
                Button("Clear") { selection.wrappedValue.removeAll() }
            }
        } label: {
            filterLabel(title, symbol: symbol, count: selection.wrappedValue.count)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var stateFilter: some View {
        Menu {
            ForEach(model.options.states) { state in
                Button { model.filters.states.toggle(state) } label: {
                    Label(state.display, systemImage: model.filters.states.contains(state) ? "checkmark" : "")
                }
            }
            if !model.filters.states.isEmpty {
                Divider(); Button("Clear") { model.filters.states.removeAll() }
            }
        } label: { filterLabel("State", symbol: "circle.dotted", count: model.filters.states.count) }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var managedFilter: some View {
        Menu {
            ForEach(SessionTriageManagedStatus.allCases) { status in
                Button { model.filters.managedStatuses.toggle(status) } label: {
                    Label(status.title, systemImage: model.filters.managedStatuses.contains(status) ? "checkmark" : "")
                }
            }
            if !model.filters.managedStatuses.isEmpty {
                Divider(); Button("Clear") { model.filters.managedStatuses.removeAll() }
            }
        } label: { filterLabel("Management", symbol: "gearshape.2", count: model.filters.managedStatuses.count) }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private func filterLabel(_ title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol); Text(title)
            if count > 0 { Text("\(count)").font(.caption2.bold()).monospacedDigit() }
        }
    }

    private var attentionBinding: Binding<Bool> {
        Binding(get: { model.filters.attentionOnly }, set: { model.filters.attentionOnly = $0 })
    }
    private var projectsBinding: Binding<Set<String>> {
        Binding(get: { model.filters.projects }, set: { model.filters.projects = $0 })
    }
    private var providersBinding: Binding<Set<String>> {
        Binding(get: { model.filters.providers }, set: { model.filters.providers = $0 })
    }
    private var workflowsBinding: Binding<Set<String>> {
        Binding(get: { model.filters.workflows }, set: { model.filters.workflows = $0 })
    }
}

private extension Set {
    mutating func toggle(_ member: Element) {
        if contains(member) { remove(member) } else { insert(member) }
    }
}

private extension View {
    func triageBadge(color: Color) -> some View {
        self.font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

#if DEBUG
#Preview("Session triage") {
    SessionTriageView(model: SessionTriageViewModel(
        sessions: SessionTriageFixtures.sessions,
        onFocus: { _ in }, onStop: { _ in }
    ))
}

#Preview("Empty") {
    SessionTriageView(model: SessionTriageViewModel(
        sessions: [], onFocus: { _ in }, onStop: { _ in }
    ))
}
#endif
