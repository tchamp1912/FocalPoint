// FocalPoint menu-bar app — entry point, app delegate, menu-bar label.
// LSUIElement (menu-bar only). Build with swiftc -parse-as-library.
// MIT License.

import SwiftUI
import AppKit

// MARK: - App delegate: owns daemon, hotkeys, overlay, settings window.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel.shared
    private var hotkeys: HotkeyManager!
    private var overlay: DesktopOverlayController!
    private var preflightWC: NSWindowController?
    private lazy var roadmapWC = RoadmapWindowCoordinator(model: model)
    /// Double-tap detection for the number hotkeys: tap focuses the session
    /// in that slot; a second tap within the window selects its workflow
    /// (focuses the run's lead). See Hotkeys.swift.
    private var slotDoubleTap = HotkeyDoubleTapTracker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let launchArguments = Set(ProcessInfo.processInfo.arguments)

        if launchArguments.contains("--dark-appearance") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        // Screenshot/smoke-test launches can keep the floating widget from
        // obscuring the window under review without changing its persisted
        // visibility preference.
        if launchArguments.contains("--hide-widget") {
            model.desktopWidgetHotkeyHidden = true
        }

        hotkeys = HotkeyManager(bindings: model.resolvedHotkeyBindings, inject: { [weak self] cmd in
            // The key1-9 hotkeys tap a slot directly (bypassing focusSession,
            // which needs a SessionInfo) — recover which session that slot
            // belongs to so `focusedSessionID` still tracks it.
            if let control = cmd["control"] as? String, control.hasPrefix("key"),
               let slot = Int(control.dropFirst(3)),
               let session = self?.model.sessions.first(where: { $0.slot == slot }) {
                if self?.slotDoubleTap.tap(slot: slot) == true,
                   let lead = self?.model.workflowRunLead(forSlot: slot) {
                    // Double-tap: select the workflow this slot belongs to by
                    // focusing the run's lead — accept/reject/PTT then route
                    // to the workflow's orchestrator, not the single member.
                    self?.model.focusSession(lead)
                } else {
                    self?.model.focusedSessionID = session.id
                }
            }
            self?.model.client.send(cmd)
        }, toggleWidget: { [weak self] in
            self?.model.desktopWidgetHotkeyHidden.toggle()
        }, focusNav: { [weak self] direction in
            switch direction {
            case .attentionNext: self?.model.focusNextAttentionSession()
            case .attentionPrev: self?.model.focusPrevAttentionSession()
            case .sessionNext:   self?.model.focusNextSession()
            case .sessionPrev:   self?.model.focusPrevSession()
            }
        })
        overlay = DesktopOverlayController(model: model)

        // Wire settings toggles to side effects. The desktop widget's own
        // visibility is self-managed (it observes model.desktopWidgetMode /
        // aggregate / sessions directly via Combine); only its "open
        // Settings" action needs wiring back into the app delegate.
        model.onHotkeysToggled = { [weak self] on in
            on ? self?.hotkeys.register() : self?.hotkeys.unregister()
        }
        // A Settings edit (record/reset) re-registers so the change is live
        // without an app restart; see HotkeyManager.updateBindings.
        model.onHotkeyBindingsChanged = { [weak self] bindings in
            self?.hotkeys.updateBindings(bindings)
        }
        overlay.onOpenSettings = { [weak self] in self?.showSettings() }
        overlay.onStartWorkflow = { [weak self] in self?.showWorkflowPreflight($0) }
        overlay.onQuickLaunch = { [weak self] in self?.showQuickLaunch() }

        model.start()
        if model.hotkeysEnabled { hotkeys.register() }
        SetupDiagnosticsWindowCoordinator.shared.presentFirstRunIfNeeded()

        // Deterministic launch routes for visual QA and automation. These
        // avoid requiring Accessibility permission merely to open a specific
        // unified-window surface for screenshots or smoke tests.
        let requestedSelection: MainWindowSelection?
        if launchArguments.contains("--open-workflows") {
            requestedSelection = .workflows
        } else if launchArguments.contains("--open-hotkeys") {
            requestedSelection = .settings(.hotkeys)
        } else if launchArguments.contains("--open-integrations") {
            requestedSelection = .settings(.integrations)
        } else if launchArguments.contains("--open-idle-style") {
            requestedSelection = .settings(.state(.idle))
        } else if launchArguments.contains("--open-settings") {
            requestedSelection = .settings(.general)
        } else {
            requestedSelection = nil
        }
        if let requestedSelection {
            DispatchQueue.main.async {
                MainWindowController.shared.show(requestedSelection)
            }
        }

        log("FocalPoint launched pid=\(ProcessInfo.processInfo.processIdentifier) (socket: \(focalpointSocketPath()))")
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("FocalPoint normal termination pid=\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// Refresh additive dashboard/diagnostic/workflow summaries when the user
    /// returns to FocalPoint; the live subscribe stream remains authoritative
    /// for session state itself.
    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshRoadmapState()
    }

    /// The unified main window (workflows + settings), landed on Behavior.
    /// The window is reused, so a plain show() keeps the user's last
    /// selection — only an explicit request forces the settings landing.
    func showSettings() {
        MainWindowController.shared.show(.settings(.general))
    }

    /// Workflow preflight for starts initiated from the desktop widget's "+"
    /// menu. The widget is a borderless, non-activating panel, so preflight
    /// gets a real window; the dropdown keeps its sheet. The launch itself
    /// goes through the shared launcher model, so the outcome reports back
    /// to both surfaces.
    func showWorkflowPreflight(_ package: FormationPackage) {
        var view = WorkflowLaunchPreflightView(
            package: package,
            suggestedDirectory: URL(fileURLWithPath: model.workflowTargetCwd, isDirectory: true),
            daemonConnected: model.connected
        ) { [weak self] configuration in
            self?.model.workflowLauncher.start(package, configuration: configuration)
        }
        let window = NSWindow()
        window.title = "Start \(package.name)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 640))
        window.isReleasedWhenClosed = false
        // The preflight view dismisses via \.dismiss (a sheet affordance);
        // re-point that at closing this window so Cancel/confirm both work.
        view.dismissOverride = { [weak window] in window?.close() }
        window.contentViewController = NSHostingController(rootView: view)
        preflightWC = NSWindowController(window: window)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        preflightWC?.showWindow(nil)
        window.center()
    }

    func showQuickLaunch() { roadmapWC.showQuickLaunch() }
    func showSchedules() { roadmapWC.showSchedules() }
    func showDiagnostics() { roadmapWC.showDiagnostics() }
}

// MARK: - Menu-bar label (icon + attention badge)

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let attention = model.attentionCount
        HStack(spacing: 2) {
            FocalPointMark(color: iconStyle, assetName: "focalpoint-mark-menubar")
                .frame(width: 14, height: 9)
                .fixedSize()
            if attention > 0 {
                // Attention badge: numeric count next to the icon.
                Text("\(attention)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(model.coloredIcon ? model.aggregateStyle.color : .primary)
            }
        }
    }

    private var iconStyle: Color {
        model.coloredIcon ? model.aggregateStyle.color : .primary
    }
}

// MARK: - Scene

@main
struct FocalPointApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model, onSettings: { appDelegate.showSettings() },
                            onQuickLaunch: { appDelegate.showQuickLaunch() },
                            onSchedules: { appDelegate.showSchedules() },
                            onDiagnostics: { appDelegate.showDiagnostics() })
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
