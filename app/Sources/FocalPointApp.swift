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
    private var settingsWC: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        hotkeys = HotkeyManager(bindings: model.resolvedHotkeyBindings, inject: { [weak self] cmd in
            // The key1-9 hotkeys tap a slot directly (bypassing focusSession,
            // which needs a SessionInfo) — recover which session that slot
            // belongs to so `focusedSessionID` still tracks it.
            if let control = cmd["control"] as? String, control.hasPrefix("key"),
               let slot = Int(control.dropFirst(3)),
               let session = self?.model.sessions.first(where: { $0.slot == slot }) {
                self?.model.focusedSessionID = session.id
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

        model.start()
        if model.hotkeysEnabled { hotkeys.register() }

        log("FocalPoint launched (socket: \(focalpointSocketPath()))")
    }

    func showSettings() {
        if settingsWC == nil {
            let vc = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: vc)
            window.title = "FocalPoint Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            // Non-opaque + transparent titlebar so the .behindWindow materials
            // in SettingsView are true see-through vibrancy, not just a
            // frosted look composited over an opaque backdrop.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            settingsWC = NSWindowController(window: window)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWC?.showWindow(nil)
        settingsWC?.window?.center()
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }
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
            MenuContentView(model: model, onSettings: { appDelegate.showSettings() })
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
