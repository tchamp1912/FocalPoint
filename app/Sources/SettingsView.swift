// FocalPoint menu-bar app — settings panes (per-state style editor + toggles).
// Since the window consolidation these are the *detail panes* hosted by
// MainWindowView's unified sidebar — the standalone Settings window is gone.
// Initialized from get-styles; sends set-style on change (sliders debounced).
// MIT License.

import SwiftUI
import Carbon

/// Coalesces rapid slider edits into one set-style per ~300 ms.
final class Debouncer {
    private var work: DispatchWorkItem?
    func call(after: TimeInterval = 0.3, _ block: @escaping () -> Void) {
        work?.cancel()
        let w = DispatchWorkItem(block: block)
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: w)
    }
}

enum SettingsSection: Hashable {
    case general
    case hotkeys
    case integrations
    case state(AgentState)
}

// MARK: - General / behavior section

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.settingsCardRhythm) {
                SettingsPageHeader(
                    title: "Behavior",
                    subtitle: "Choose how FocalPoint behaves, appears, and opens managed sessions.",
                    symbol: "gearshape"
                )

                VStack(alignment: .leading, spacing: 14) {
                    SettingsCardHeader(title: "App behavior")
                    Toggle("Enable global hotkeys", isOn: $model.hotkeysEnabled)
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Colored status icon", isOn: $model.coloredIcon)
                        Text("The menu-bar icon is a neutral template by default; it adds a badge when a session needs attention. Turn this on to tint it by aggregate state.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 14) {
                    SettingsCardHeader(
                        title: "Desktop widget",
                        subtitle: "Control when the floating session monitor appears and how it lays out sessions."
                    )
                    Divider()
                    Picker("Visibility", selection: $model.desktopWidgetMode) {
                        ForEach(DesktopWidgetMode.allCases) { mode in
                            Text(mode.display).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text("Auto-hide keeps the widget out of the way while every session is idle and restores it when something needs attention.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Text("Orientation")
                        Spacer()
                        Picker("Orientation", selection: $model.desktopWidgetOrientation) {
                            ForEach(DesktopWidgetOrientation.allCases) { option in
                                Text(option.display).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }
                    if let width = model.widgetWidth(for: model.desktopWidgetOrientation) {
                        HStack {
                            Text("Custom width")
                            Spacer()
                            Text("\(Int(width)) pt")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button("Reset to Automatic") {
                                model.resetWidgetWidth(for: model.desktopWidgetOrientation)
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("Horizontal renders the pad as a compact key strip. Drag the widget's bottom-right corner to cap its width; widths are remembered separately for each orientation.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Compact session rows", isOn: $model.compactWidgetRows)
                        Text("Hides the stats row and context meter in the widget; both remain available in the dropdown.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 10) {
                    SettingsCardHeader(
                        title: "Widget appearance",
                        subtitle: "Adjust only the floating widget's background; text and icons remain fully opaque."
                    )
                    Divider()
                    HStack {
                        Text("Translucency")
                        Spacer()
                        Text("\(Int(model.interfaceTranslucency * 100))%")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $model.interfaceTranslucency, in: 0.05...1.0, step: 0.01)
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 12) {
                    SettingsCardHeader(
                        title: "Terminal",
                        subtitle: "Used for managed launches, Open in Terminal, and History → Resume."
                    )
                    HStack {
                        Picker("Terminal app", selection: $model.terminalBundleID) {
                            Text("System default").tag("")
                            ForEach(model.installedTerminalApps, id: \.id) { app in
                                Text(app.name).tag(app.id)
                            }
                            // Keep a hand-picked app that isn't in the known
                            // list selectable so the picker reflects reality.
                            if !model.terminalBundleID.isEmpty,
                               !model.installedTerminalApps.contains(where: { $0.id == model.terminalBundleID }) {
                                Text(model.terminalDisplayName).tag(model.terminalBundleID)
                            }
                        }
                        .frame(maxWidth: 220)
                        Spacer()
                        Button("Choose\u{2026}") { model.chooseTerminalApp() }
                    }
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 8) {
                    SettingsCardHeader(title: "Reset state styles")
                    HStack {
                        Text("Restore every state's color, pattern, and period to its shipped default.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset All to Defaults", role: .destructive) { model.resetStyles() }
                    }
                }
                .settingsCard()

                Spacer(minLength: 0)
            }
            .settingsPageLayout()
        }
    }
}

// MARK: - Agent integrations section

struct IntegrationsSettingsView: View {
    @ObservedObject var model: AppModel

    private let roadmap: [(icon: String, title: String, detail: String)] = [
        ("network", "MCP server health",
         "Surface a session's connected MCP servers and flag one that's disconnected or erroring, since that's often the real reason a session looks \u{201C}stuck\u{201D}."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.settingsCardRhythm) {
                SettingsPageHeader(
                    title: "Agent Integrations",
                    subtitle: "Configure provider-specific context, usage reporting, badges, and alerts.",
                    symbol: "sparkles"
                )

                VStack(alignment: .leading, spacing: 14) {
                    SettingsCardHeader(title: "Context window")
                    Text("Per-provider cap for the meter under each session row. Leave on Auto to use the adapter-reported window when available. Set a lower number to match your compact/rot preference — the bar turns red at 100% of your cap even if the model allows more.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    contextWindowField(kind: "claude", title: "Claude Code",
                                       hint: "Run /context and use Auto-compact window. Default 967k on first install.")
                    contextWindowField(kind: "codex", title: "Codex CLI",
                                       hint: "Usually reported automatically (~258k). Override to warn earlier.")
                    contextWindowField(kind: "cursor", title: "Cursor",
                                       hint: "Cursor does not report occupancy yet; set a cap if you add context data later.")
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 14) {
                    SettingsCardHeader(title: "Session stat badges")
                    Text("Shown next to a session's elapsed time when the adapter reports them. A stat you enable here simply stays hidden for sessions that don't have data for it yet — nothing to configure per-adapter.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(SessionStat.allCases) { stat in
                        Toggle(isOn: statBinding(stat)) {
                            Label(stat.label, systemImage: stat.symbol)
                        }
                    }
                    Divider()
                    Toggle("Show model badge", isOn: $model.showModelBadge)
                    Text("Shows which model is driving the session (e.g. Sonnet, Composer, or GPT-5.6) next to each row.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Claude Code and Codex CLI report tokens, turns, tool calls, and subagents from local session data. Cursor 3.13+ reports the same badges using stop-hook token usage plus its transcript; older Cursor versions omit tokens. Cost is Claude Code only, reported by its status-line hook as a real dollar figure (not an estimate).")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 10) {
                    SettingsCardHeader(title: "Provider usage")
                    Toggle("Show account usage monitor", isOn: $model.showUsage)
                    Text("The monitor displays provider-reported subscription quota and reset times, not estimates from session token counts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Track API usage totals", isOn: $model.apiUsageTrackingEnabled)
                    HStack {
                        Text("Tracks Claude, Cursor, and OpenAI API values locally from this point onward. Resetting never changes provider billing or limits.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset totals") { model.resetAPIUsageTracking() }
                            .buttonStyle(.bordered)
                            .disabled(!model.apiUsageTrackingEnabled)
                    }
                    Divider()
                    Text("Claude Code")
                        .font(.subheadline).bold()
                    Text("Install the FocalPoint status-line reporter for subscription limits. Set ANTHROPIC_ADMIN_KEY to show exact API input/output tokens and spend for today; the admin key is used only for Anthropic's Usage and Cost reports and is never stored or sent to the daemon.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Codex")
                        .font(.subheadline).bold()
                    Toggle("Read Codex/OpenAI usage", isOn: $model.codexUsageEnabled)
                    Text("Uses a local Codex app-server process and your existing ChatGPT authentication for quota. To show API-billed spend, launch FocalPoint with OPENAI_ADMIN_KEY; the key is used only for OpenAI's organization Costs API, never stored or sent to the daemon. Ordinary API keys cannot read organization billing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Cursor")
                        .font(.subheadline).bold()
                    Toggle("Read Cursor quota from local sign-in", isOn: $model.cursorUsageEnabled)
                    Text("Reads included usage from the local Cursor sign-in. Set CURSOR_ADMIN_API_KEY to show exact team API spend for the current cycle; it is used only for Cursor's Admin API and is never stored or sent to the daemon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 14) {
                    SettingsCardHeader(title: "Budget alerts")
                    Text("When either threshold below is set and a session crosses it — tokens (in + out) or total cost, whichever trips first — that session's row tints to a warning color in the dropdown and the desktop widget. Purely local and visual: nothing is sent to the daemon, an adapter, or anywhere else. Leave a field blank to turn that threshold off.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Label("Token budget", systemImage: "number")
                        Spacer()
                        TextField("Off", text: tokenBudgetText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 100)
                    }
                    HStack {
                        Label("Cost budget", systemImage: "dollarsign.circle")
                        Spacer()
                        Text("$").foregroundStyle(.secondary)
                        TextField("Off", text: costBudgetText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 14) {
                    SettingsCardHeader(title: "Stale sessions")
                    Text("For integrations whose process or tmux pane cannot be verified, optionally dim an active-looking session after this many minutes without an adapter event. Healthy sessions use the daemon's 15-second attachment heartbeat and never become stale from age alone. This is display-only and defaults to Off.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Label("Stale after", systemImage: "moon.zzz")
                        Spacer()
                        TextField("Off", text: staleThresholdText)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                        Text("min").foregroundStyle(.secondary)
                    }
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 14) {
                    SettingsCardHeader(title: "Ideas / roadmap")
                    Text("Not implemented yet — listed here so they don't get lost.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(roadmap, id: \.title) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.callout)
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .settingsCard()

                Spacer(minLength: 0)
            }
            .settingsPageLayout()
        }
    }

    private func statBinding(_ stat: SessionStat) -> Binding<Bool> {
        Binding(
            get: { model.visibleStats.contains(stat) },
            set: { on in
                if on { model.visibleStats.insert(stat) } else { model.visibleStats.remove(stat) }
            }
        )
    }

    /// String shim for `model.tokenBudget: Int?` — an empty field is "off"
    /// (`nil`), matching the UserDefaults nil-safe treatment in AppModel.
    /// Non-digit input is dropped rather than rejected outright, so pasting
    /// "10,000" still lands on something sane instead of doing nothing.
    private var tokenBudgetText: Binding<String> {
        Binding(
            get: { model.tokenBudget.map(String.init) ?? "" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                model.tokenBudget = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    /// String shim for `model.costBudget: Double?`, same clearable treatment.
    private var costBudgetText: Binding<String> {
        Binding(
            get: { model.costBudget.map { String(format: "%.2f", $0) } ?? "" },
            set: { newValue in
                let cleaned = newValue.filter { $0.isNumber || $0 == "." }
                model.costBudget = cleaned.isEmpty ? nil : Double(cleaned)
            }
        )
    }

    /// String shim for `model.staleThresholdMinutes: Int?`, same clearable
    /// treatment as the budget fields.
    private var staleThresholdText: Binding<String> {
        Binding(
            get: { model.staleThresholdMinutes.map(String.init) ?? "" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                model.staleThresholdMinutes = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    @ViewBuilder
    private func contextWindowField(kind: String, title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: "arrow.left.and.right.square")
                Spacer()
                TextField("Auto", text: contextWindowBinding(kind))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                Text("tokens").font(.caption).foregroundStyle(.secondary)
            }
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func contextWindowBinding(_ kind: String) -> Binding<String> {
        Binding(
            get: { model.contextWindowByKind[kind].map(String.init) ?? "" },
            set: { newValue in
                let digits = newValue.filter(\.isNumber)
                if digits.isEmpty {
                    model.contextWindowByKind.removeValue(forKey: kind)
                } else if let value = Int(digits) {
                    model.contextWindowByKind[kind] = value
                }
            }
        )
    }
}

// MARK: - Per-state style editor

struct StateStyleDetail: View {
    @ObservedObject var model: AppModel
    let state: AgentState
    @State private var debouncer = Debouncer()

    private var style: StateStyle { model.styles[state] ?? defaultStyle(state) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.settingsCardRhythm) {
                SettingsPageHeader(
                    title: state.display,
                    subtitle: "Customize the color and animation shown when a session is \(state.display.lowercased()).",
                    symbol: state.symbolName,
                    tint: style.color
                ) {
                    Button("Reset") { model.setStyle(state, defaultStyle(state)) }
                }

                if model.connected && !model.stylesSupported {
                    Text("This daemon doesn\u{2019}t support styles yet — edits are kept locally and set-style attempts may not apply.")
                        .font(.caption).foregroundStyle(.orange)
                } else if !model.connected {
                    Text("Daemon offline — showing defaults; changes apply when it reconnects.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 16) {
                    SettingsCardHeader(title: "State appearance")
                    Divider()
                    HStack {
                        Text("Color").font(.subheadline)
                        Spacer()
                        ColorPicker("", selection: colorBinding, supportsOpacity: false)
                            .labelsHidden()
                    }
                    Divider()
                    HStack {
                        Text("Pattern").font(.subheadline)
                        Spacer()
                        Picker("", selection: patternBinding) {
                            ForEach(Pattern.allCases) { p in Text(p.display).tag(p) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Period").font(.subheadline)
                            Spacer()
                            Text("\(style.periodMs) ms")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: periodBinding, in: 100...5000, step: 50)
                    }
                }
                .settingsCard()

                Spacer(minLength: 0)
            }
            .settingsPageLayout()
        }
        .id(state) // fresh identity per state so debounced edits never bleed across rows
    }

    // MARK: Bindings

    private var colorBinding: Binding<Color> {
        Binding(
            get: { style.color },
            set: { newColor in
                let rgb = rgbComponents(newColor)
                var s = style; s.rgb = rgb
                model.setStyle(state, s)   // ColorPicker edits are discrete; no debounce needed
            }
        )
    }

    private var patternBinding: Binding<Pattern> {
        Binding(
            get: { style.pattern },
            set: { var s = style; s.pattern = $0; model.setStyle(state, s) }
        )
    }

    private var periodBinding: Binding<Double> {
        Binding(
            get: { Double(style.periodMs) },
            set: { newVal in
                var s = style; s.periodMs = Int(newVal)
                model.styles[state] = s              // update UI immediately
                debouncer.call { model.setStyle(state, s) }   // debounce the wire send
            }
        )
    }

    private func rgbComponents(_ color: Color) -> [Int] {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return [max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b))]
    }
}

// MARK: - Hotkeys section

/// One row per bindable action: current combo (or "Press a key combo…"
/// while recording), a Record/Cancel button, and a per-row Reset. Recording
/// captures the next raw NSEvent via a local monitor rather than Carbon
/// (Carbon can only report combos it's already registered to listen for).
struct HotkeysSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var recordingAction: HotkeyActionID?
    @State private var warning: String?
    @State private var monitor: Any?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.settingsCardRhythm) {
                SettingsPageHeader(
                    title: "Hotkeys",
                    subtitle: "Global shortcuts work without Accessibility permission and always require a modifier key.",
                    symbol: "keyboard"
                ) {
                    Button("Reset All to Defaults", role: .destructive) {
                        cancelRecording()
                        model.resetAllHotkeyBindings()
                    }
                }

                Label("Double-tap a Focus Session number to select its workflow lead; Accept, Reject, and Push to Talk then route to the orchestrator.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .settingsCard(.alert)

                VStack(spacing: 0) {
                    ForEach(HotkeyActionID.allCases) { action in
                        hotkeyRow(action)
                        if action != HotkeyActionID.allCases.last {
                            Divider().padding(.leading, 4)
                        }
                    }
                }
                .settingsCard(.list)

                Spacer(minLength: 0)
            }
            .settingsPageLayout()
        }
        .onDisappear { cancelRecording() }
    }

    @ViewBuilder
    private func hotkeyRow(_ action: HotkeyActionID) -> some View {
        let binding = model.resolvedHotkeyBindings[action] ?? action.defaultBinding
        let isRecording = recordingAction == action
        let isCustomized = model.hotkeyBindings[action.rawValue] != nil

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(action.label).font(.body)
                Spacer()
                if isRecording {
                    Text("Press a key combo\u{2026}")
                        .font(.caption).foregroundStyle(.orange)
                } else {
                    Text(KeyCodeNames.comboString(keyCode: binding.keyCode, modifiers: binding.modifiers))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .liquidGlass(.chip, radius: 5)
                }
                Button(isRecording ? "Cancel" : "Record") {
                    isRecording ? cancelRecording() : startRecording(action)
                }
                .buttonStyle(.bordered)
                Button("Reset") { model.resetHotkeyBinding(action) }
                    .buttonStyle(.borderless)
                    .disabled(!isCustomized)
            }
            if isRecording, let warning {
                Text(warning).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: Metrics.rowRadius, style: .continuous)
            .fill(isRecording ? Color.orange.opacity(0.12) : .clear))
    }

    private func startRecording(_ action: HotkeyActionID) {
        cancelRecording()
        recordingAction = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event, for: action)
            return nil   // swallow the event while listening
        }
    }

    private func handleKeyDown(_ event: NSEvent, for action: HotkeyActionID) {
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }
        let modifiers = KeyCodeNames.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            // Refuse bare unmodified keys outright — that would break normal
            // typing system-wide. Keep listening so the user can try again.
            warning = "Add at least one modifier key (\u{2303}\u{2325}\u{21E7}\u{2318})."
            return
        }
        let keyCode = UInt32(event.keyCode)
        if let conflict = model.conflictingHotkeyAction(keyCode: keyCode, modifiers: modifiers,
                                                         excluding: action) {
            // Blocks the save rather than swapping — the user resets or
            // rebinds the other action first, so no binding is silently lost.
            warning = "\u{201C}\(KeyCodeNames.comboString(keyCode: keyCode, modifiers: modifiers))\u{201D} is already used by \u{201C}\(conflict.label)\u{201D}. Choose another combo, or reset that binding first."
            return
        }
        model.setHotkeyBinding(action, keyCode: keyCode, modifiers: modifiers)
        cancelRecording()
    }

    private func cancelRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingAction = nil
        warning = nil
    }
}
