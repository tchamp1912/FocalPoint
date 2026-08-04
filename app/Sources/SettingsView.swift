// FocalPoint menu-bar app — settings window (per-state style editor + toggles).
// Sidebar/detail layout: a list of General + the 6 states on the left (with
// a live swatch preview per state), an editor for the selected item on the
// right. Scales much better than a flat repeated-group list.
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
    case history
    case state(AgentState)
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 210)
        .frame(width: 580, height: 440)
        // NavigationSplitView paints its own opaque NSSplitViewController
        // background on macOS regardless of window.isOpaque/backgroundColor
        // — without this, the sidebar/detail VisualEffectViews and glass
        // cards render correctly but sit on a solid backing, so none of it
        // reads as translucent.
        .background(.clear)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("General") {
                Label("Behavior", systemImage: "gearshape")
                    .tag(SettingsSection.general)
                Label("Hotkeys", systemImage: "keyboard")
                    .tag(SettingsSection.hotkeys)
                Label("Agent Integrations", systemImage: "sparkles")
                    .tag(SettingsSection.integrations)
                Label("History", systemImage: "clock.arrow.circlepath")
                    .tag(SettingsSection.history)
            }
            Section("State styles") {
                ForEach(AgentState.allCases) { state in
                    HStack(spacing: 8) {
                        StateSwatch(state: state, color: (model.styles[state] ?? defaultStyle(state)).color, size: 10)
                        Text(state.display)
                    }
                    .tag(SettingsSection.state(state))
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // Opacity on the material layer only — never on the window itself —
        // so turning translucency up fades the glass toward raw desktop
        // without touching the legibility of the list text. Goes through
        // Glass.swift like every other surface so macOS 26 gets real Liquid
        // Glass here too, instead of always the pre-26 vibrancy material.
        .liquidGlass(.sidebarPane(opacity: Metrics.settingsPaneOpacity), radius: 0)
    }

    @ViewBuilder
    private var detail: some View {
        ZStack {
            Color.clear
                .liquidGlass(.detailPane(opacity: Metrics.settingsPaneOpacity), radius: 0)
                .ignoresSafeArea()
            // Groups the section's cards so macOS 26 renders them as one
            // material; a pass-through on older systems.
            LiquidGlassGroup(spacing: 22) {
                switch selection {
                case .state(let s):
                    StateStyleDetail(model: model, state: s)
                case .hotkeys:
                    HotkeysSettingsView(model: model)
                case .integrations:
                    IntegrationsSettingsView(model: model)
                case .history:
                    SessionHistoryView(model: model)
                case .general, .none:
                    GeneralSettingsView(model: model)
                }
            }
        }
    }
}

// MARK: - General / behavior section

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Behavior").font(.title3).bold()

                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Enable global hotkeys", isOn: $model.hotkeysEnabled)
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Colored status icon", isOn: $model.coloredIcon)
                        Text("The menu-bar icon is a neutral template by default; it adds a badge when a session needs attention. Turn this on to tint it by aggregate state.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Desktop widget").font(.subheadline).bold()
                        Picker("", selection: $model.desktopWidgetMode) {
                            ForEach(DesktopWidgetMode.allCases) { mode in
                                Text(mode.display).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.radioGroup)
                        Text("Auto-hide keeps the desktop widget out of the way while every session is idle; it reappears the moment something needs attention.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Desktop widget translucency").font(.subheadline).bold()
                            Spacer()
                            Text("\(Int(model.interfaceTranslucency * 100))%")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Slider(value: $model.interfaceTranslucency, in: 0.05...1.0, step: 0.01)
                        Text("Fades only the widget's frosted background — text and icons stay fully readable. Settings stays opaque for legibility.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Terminal").font(.title3).bold()
                    Text("Which app FocalPoint opens when you launch a session \u{2014} \u{201C}Open in Terminal\u{201D} and History \u{2192} Resume.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("", selection: $model.terminalBundleID) {
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
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        Spacer()
                        Button("Choose\u{2026}") { model.chooseTerminalApp() }
                    }
                }
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reset").font(.title3).bold()
                    HStack {
                        Text("Restore every state's color, pattern, and period to its shipped default.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset All to Defaults", role: .destructive) { model.resetStyles() }
                    }
                }
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }
}

// MARK: - History section

struct SessionHistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("History").font(.title3).bold()

                if model.sessionHistory.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text("No sessions yet").font(.body).foregroundStyle(.secondary)
                        Text("Completed sessions will show up here.")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                    .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.sessionHistory) { entry in
                            historyRow(entry)
                            if entry.id != model.sessionHistory.last?.id { Divider() }
                        }
                    }
                    .padding(16)
                    .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                    HStack {
                        Text("\(model.sessionHistory.count) session\(model.sessionHistory.count == 1 ? "" : "s") kept, most recent first.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear History", role: .destructive) { model.clearSessionHistory() }
                    }
                    .padding(16)
                    .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private func historyRow(_ entry: SessionHistoryEntry) -> some View {
        HStack(spacing: 10) {
            StateSwatch(state: entry.finalState,
                        color: (model.styles[entry.finalState] ?? defaultStyle(entry.finalState)).color, size: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.body)
                HStack(spacing: 5) {
                    Text(entry.kind).font(.caption2).foregroundStyle(.tertiary)
                    if let cwd = entry.cwd {
                        Text(cwd).font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            Spacer(minLength: 8)
            if model.resumeCommand(for: entry) != nil {
                Button { model.recoverSession(entry) } label: {
                    Label("Resume Managed", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reopen this \(entry.kind) conversation under FocalPoint's managed tmux transport")
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(durationString(entry.endedAt.timeIntervalSince(entry.startedAt)))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                Text("\(elapsedString(since: entry.endedAt)) ago")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            if model.resumeCommand(for: entry) != nil {
                Button("Resume as Managed Session") { model.recoverSession(entry) }
                Divider()
            }
            if let cwd = entry.cwd {
                Button("Open in Terminal") { model.openInTerminal(cwd) }
                Button("Show in Finder") { model.revealInFinder(cwd) }
                Button("Copy Working Directory") { model.copyToPasteboard(cwd) }
            }
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
            VStack(alignment: .leading, spacing: 22) {
                Text("Agent Integrations").font(.title3).bold()
                Text("Features specific to Claude Code, Cursor, and Codex CLI sessions rather than the protocol in general.")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Context window").font(.subheadline).bold()
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
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Session stat badges").font(.subheadline).bold()
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
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Show account usage monitor", isOn: $model.showUsage)
                    Text("The monitor displays provider-reported subscription quota and reset times, not estimates from session token counts.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Text("Claude Code")
                        .font(.subheadline).bold()
                    Text("Install the FocalPoint status-line reporter in Claude Code. It forwards only the documented rate-limit percentages and reset timestamps locally; prompts, tools, and transcript contents are never sent.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Codex")
                        .font(.subheadline).bold()
                    Toggle("Read Codex quota with app-server", isOn: $model.codexUsageEnabled)
                    Text("Uses a local Codex app-server process and your existing ChatGPT authentication for quota. To show API-billed spend, launch FocalPoint with OPENAI_ADMIN_KEY; the key is used only for OpenAI's organization Costs API, never stored or sent to the daemon. Ordinary API keys cannot read organization billing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Cursor")
                        .font(.subheadline).bold()
                    Toggle("Read Cursor quota from local sign-in", isOn: $model.cursorUsageEnabled)
                    Text("Reads your Cursor access token from the local app database and queries Cursor's dashboard API for included API and Auto usage. Requires Cursor to be signed in; prompts and session data are never sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Budget alerts").font(.subheadline).bold()
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
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Stale sessions").font(.subheadline).bold()
                    Text("A session can be left showing \u{201C}Thinking\u{201D}/\u{201C}Running\u{201D}/\u{201C}Waiting\u{201D} forever if its agent process dies without a clean shutdown \u{2014} crashed, terminal closed, laptop slept. After this many minutes with no update, that session dims and shows as possibly-stale instead of implying it's still working. This is only a display heads-up — it doesn't end the session; the daemon's own longer session.ttl_minutes (config.toml) still owns that. Leave blank to turn this off.")
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
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Ideas / roadmap").font(.subheadline).bold()
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
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                Spacer(minLength: 0)
            }
            .padding(20)
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
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    StateSwatch(state: state, color: style.color, size: 18)
                    Text(state.display).font(.title2).bold()
                    Spacer()
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
                .padding(16)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                Spacer(minLength: 0)
            }
            .padding(20)
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
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Hotkeys").font(.title3).bold()
                    Spacer()
                    Button("Reset All to Defaults", role: .destructive) {
                        cancelRecording()
                        model.resetAllHotkeyBindings()
                    }
                }
                Text("Global hotkeys work system-wide without Accessibility permission. Every combo must include at least one modifier key (\u{2303}\u{2325}\u{21E7}\u{2318}) so normal typing elsewhere is never affected.")
                    .font(.caption).foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(HotkeyActionID.allCases) { action in
                        hotkeyRow(action)
                        if action != HotkeyActionID.allCases.last {
                            Divider().padding(.leading, 4)
                        }
                    }
                }
                .padding(12)
                .liquidGlass(.settingsCard, radius: Metrics.rowRadius * 1.5)

                Spacer(minLength: 0)
            }
            .padding(20)
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
