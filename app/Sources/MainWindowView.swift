// FocalPoint menu-bar app — the unified main window.
//
// One window instead of four: live session surfaces (triage, workflow runs,
// history) and Settings share a single sidebar. Workflows are a *settings
// subsection* — one sidebar row whose detail pane hosts the full package
// manager (formations, agent types, bundled catalog) as its own internal
// master-detail, so the sidebar stays quiet no matter how many packages
// are installed. The old standalone Settings, Workflow Editor, Triage, and
// History windows are gone; AppDelegate.showSettings(), the launch menu's
// "Workflow Editor…", and the dropdown's workspace items all land here
// (MainWindowController at the bottom of this file).
// MIT License.

import SwiftUI
import AppKit
import Combine

/// Sidebar identity across the domains this window merges.
enum MainWindowSelection: Hashable {
    /// Live session triage (Sessions section).
    case triage
    /// The live workflow-runs dashboard (Sessions section).
    case runs
    /// The history workspace (Sessions section).
    case history
    /// The workflow package manager (a Settings subsection; its internal
    /// formation/agent-type selection lives in WorkflowEditorModel).
    case workflows
    case settings(SettingsSection)
}

struct MainWindowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: WorkflowEditorModel
    /// External "show this section" requests from the window controller
    /// (e.g. the launch menu's "Workflow Editor…" landing on Workflows).
    let selectionRequests: PassthroughSubject<MainWindowSelection, Never>

    @State private var selection: MainWindowSelection?

    init(model: AppModel, store: WorkflowEditorModel,
         initialSelection: MainWindowSelection,
         selectionRequests: PassthroughSubject<MainWindowSelection, Never>) {
        self.model = model
        self.store = store
        self.selectionRequests = selectionRequests
        _selection = State(initialValue: initialSelection)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .liquidGlass(.detailPane(opacity: Metrics.settingsPaneOpacity), radius: 0)
        }
        // A full-size app window, not a settings panel: the minimum fits the
        // widest detail (the runs dashboard wants ~820pt) plus the sidebar.
        .frame(minWidth: 1060, idealWidth: 1280, minHeight: 640, idealHeight: 800)
        // Pane materials provide the visual hierarchy; the NSWindow itself
        // supplies an adaptive opaque base so content from other apps never
        // competes with settings labels through the glass.
        .background(.clear)
        .onAppear { store.reload() }
        .onReceive(selectionRequests) { selection = $0 }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Sessions") {
                Label("Session Triage", systemImage: "list.bullet.rectangle")
                    .tag(MainWindowSelection.triage)
                Label("Workflow Runs", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(MainWindowSelection.runs)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(MainWindowSelection.history)
            }
            Section("Settings") {
                Label("Behavior", systemImage: "gearshape")
                    .tag(MainWindowSelection.settings(.general))
                Label("Hotkeys", systemImage: "keyboard")
                    .tag(MainWindowSelection.settings(.hotkeys))
                Label("Agent Integrations", systemImage: "sparkles")
                    .tag(MainWindowSelection.settings(.integrations))
                Label("Workflows", systemImage: "flowchart")
                    .tag(MainWindowSelection.workflows)
            }
            Section("State Styles") {
                ForEach(AgentState.allCases) { state in
                    HStack(spacing: 8) {
                        StateSwatch(state: state, color: (model.styles[state] ?? defaultStyle(state)).color, size: 10)
                        Text(state.display)
                    }
                    .tag(MainWindowSelection.settings(.state(state)))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Opacity on the material layer only — never on the window itself —
        // so translucency never dims the list text.
        .liquidGlass(.sidebarPane(opacity: Metrics.settingsPaneOpacity), radius: 0)
    }

    // MARK: Detail routing

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .triage:
            LiveSessionTriageView(model: model)
        case .runs:
            LiveWorkflowDashboardView(model: model)
        case .history:
            LiveHistoryWorkspaceView(model: model)
        case .workflows:
            WorkflowsPage(store: store)
        case .settings(let section):
            settingsDetail(section)
        case nil:
            LiveWorkflowDashboardView(model: model)
        }
    }

    @ViewBuilder
    private func settingsDetail(_ section: SettingsSection) -> some View {
        // No GlassEffectContainer here: cards draw glass as a background
        // layer (see Glass.swift), and a container hoists those layers
        // *above* the controls they belong behind.
        switch section {
        case .state(let state):
            StateStyleDetail(model: model, state: state)
        case .hotkeys:
            HotkeysSettingsView(model: model)
        case .integrations:
            IntegrationsSettingsView(model: model)
        case .general:
            GeneralSettingsView(model: model)
        }
    }
}

// MARK: - Workflows page

/// The workflow package manager as a Settings subsection: the package lists
/// (formations, agent types, bundled catalog) in a narrow column with the
/// create/delete/reload controls, and the editor's detail views beside
/// them. Selection is the editor store's own — nothing here leaks into the
/// window's sidebar.
private struct WorkflowsPage: View {
    @ObservedObject var store: WorkflowEditorModel
    @State private var confirmingDelete = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                packageList
                Divider()
                bottomControls
            }
            .frame(width: 232)
            Divider()
            WorkflowEditorDetailView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Move to Trash?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) {
                if let selection = store.selection { store.delete(selection) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The package directory is moved to the Trash and can be restored from there.")
        }
    }

    private var packageList: some View {
        List(selection: $store.selection) {
            Section("Workflows") {
                ForEach(store.formations) { formation in
                    packageRow(title: formation.name,
                               detail: formationDetail(formation),
                               symbol: "person.3.sequence",
                               dirty: store.isDirty(formation))
                        .tag(EditorSelection.formation(formation.id))
                }
                ForEach(store.broken.filter { $0.kind == .formation }) { package in
                    packageRow(title: package.id, detail: "Malformed", symbol: "exclamationmark.triangle",
                               dirty: false, tint: .orange)
                        .tag(EditorSelection.broken(.formation, package.id))
                }
            }
            Section("Agent Types") {
                ForEach(store.agentTypes) { type in
                    packageRow(title: type.name,
                               detail: type.prefer.joined(separator: " › "),
                               symbol: "person.crop.square",
                               dirty: store.isDirty(type))
                        .tag(EditorSelection.agentType(type.id))
                }
                ForEach(store.broken.filter { $0.kind == .agentType }) { package in
                    packageRow(title: package.id, detail: "Malformed", symbol: "exclamationmark.triangle",
                               dirty: false, tint: .orange)
                        .tag(EditorSelection.broken(.agentType, package.id))
                }
            }
            Section("Bundled Catalog") {
                ForEach(store.bundledFormations) { formation in
                    packageRow(title: formation.name, detail: formationDetail(formation),
                               symbol: "shippingbox", dirty: false, tint: .accentColor)
                        .tag(EditorSelection.bundledFormation(formation.id))
                }
                ForEach(store.bundledAgentTypes) { type in
                    packageRow(title: type.name, detail: type.prefer.joined(separator: " › "),
                               symbol: "shippingbox", dirty: false, tint: .accentColor)
                        .tag(EditorSelection.bundledAgentType(type.id))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    private var bottomControls: some View {
        HStack(spacing: 10) {
            Menu {
                Button("New Workflow") { store.createFormation() }
                Button("New Agent Type") { store.createAgentType() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("Create a new package")
            Button { confirmingDelete = true } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.selection == nil)
            .help("Move the selected package to the Trash")
            Spacer()
            Button { store.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reload from disk (unsaved edits are kept)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func packageRow(title: String, detail: String, symbol: String,
                            dirty: Bool, tint: Color? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if dirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
        }
        .padding(.vertical, 2)
    }

    private func formationDetail(_ formation: EditableFormation) -> String {
        if formation.phased {
            return "\(formation.phases.count) phase\(formation.phases.count == 1 ? "" : "s")"
        }
        return "\(formation.roles.count) role\(formation.roles.count == 1 ? "" : "s")"
    }
}

// MARK: - Window controller

/// Owns the one unified FocalPoint window. Singleton because callers are
/// scattered (app delegate, launch menu, widget); the diagnostics callback
/// is configured once by the app delegate at launch.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static let shared = MainWindowController()

    private var windowController: NSWindowController?
    private let store = WorkflowEditorModel()
    /// Post-creation "show this section" events. The first show's selection
    /// rides in through the view's initializer instead — a PassthroughSubject
    /// has no replay, and the view graph may not have subscribed yet.
    private let selectionRequests = PassthroughSubject<MainWindowSelection, Never>()

    /// Show the window. `selection` forces a landing section; nil keeps
    /// whatever the user last selected (the window is reused, so @State
    /// persists across closes).
    func show(_ selection: MainWindowSelection? = nil) {
        if windowController == nil {
            let root = MainWindowView(
                model: AppModel.shared,
                store: store,
                initialSelection: selection ?? .runs,
                selectionRequests: selectionRequests
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "FocalPoint"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // This is a reading/editing surface, not the floating widget.
            // Keep a normal adaptive window base and layer pane/card glass
            // inside it; otherwise a busy app behind FocalPoint shows through
            // every empty area and makes the UI look inconsistent.
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setFrameAutosaveName("FocalPointMainWindow")
            if !window.setFrameUsingName("FocalPointMainWindow") {
                // First launch: open at a real app-window size (autosave
                // takes over from the first resize onwards).
                window.setContentSize(NSSize(width: 1280, height: 800))
                window.center()
            }
            windowController = NSWindowController(window: window)
        } else if let selection {
            selectionRequests.send(selection)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        AppModel.shared.mainWindowVisible = true
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        store.reload()
    }

    /// The "Workflow Editor…" menu item's landing: the Workflows page when
    /// a package is (or was last) selected, else the runs dashboard.
    func showWorkflows() {
        show(store.selection != nil ? .workflows : .runs)
    }

    func windowWillClose(_ notification: Notification) {
        AppModel.shared.mainWindowVisible = false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        AppModel.shared.mainWindowVisible = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        AppModel.shared.mainWindowVisible = true
    }
}
