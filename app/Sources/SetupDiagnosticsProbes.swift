// FocalPoint setup diagnostics — production-safe local probes and fixes.
// MIT License.

import AppKit
import ApplicationServices
import Foundation
import ServiceManagement

struct LocalSetupDiagnosticCheck: SetupDiagnosticChecking {
    let id: SetupDiagnosticID
    private let operation: @Sendable () async -> SetupDiagnosticResult

    init(id: SetupDiagnosticID,
         operation: @escaping @Sendable () async -> SetupDiagnosticResult) {
        self.id = id
        self.operation = operation
    }

    func run() async -> SetupDiagnosticResult { await operation() }
}

enum LocalSetupDiagnostics {
    static func checks() -> [any SetupDiagnosticChecking] {
        [daemonCheck(), adaptersCheck(), tmuxCheck(), permissionsCheck(),
         loginStartupCheck(), providersCheck()]
    }

    private static func daemonCheck() -> LocalSetupDiagnosticCheck {
        .init(id: .daemon) {
            await Task.detached {
                let path = focalpointSocketPath()
                let socketExists = FileManager.default.fileExists(atPath: path)
                guard let fd = focalpointConnect(recvTimeout: 0.75) else {
                    return SetupDiagnosticResult(
                        id: .daemon,
                        status: .failed,
                        summary: socketExists
                            ? "The daemon socket exists but is not accepting connections."
                            : "The daemon socket was not found.",
                        evidence: [
                            .init("Socket", socketExists ? "Present at ~/…/focalpoint.sock" : "Not found"),
                            .init("Protocol handshake", "Unavailable")
                        ],
                        actions: [
                            .init(.startDaemon, title: "Start daemon", isPrimary: true),
                            .init(.copyInstallCommand, title: "Copy install command"),
                            .init(.recheck, title: "Recheck")
                        ])
                }
                defer { close(fd) }
                guard let request = focalpointEncode(["cmd": "get-diagnostics"]),
                      focalpointSendLine(fd, request) else {
                    return SetupDiagnosticResult(
                        id: .daemon, status: .failed,
                        summary: "Connected, but could not send a protocol request.",
                        evidence: [.init("Socket", "Connected"), .init("Protocol handshake", "Failed")],
                        actions: [.init(.recheck, title: "Recheck", isPrimary: true)])
                }
                var response: [String: Any]?
                focalpointReadLines(fd) { object in
                    response = object
                    return false
                }
                let receivedResponse = response?["ok"] as? Bool == true
                let needingReview = (response?["sessions_needing_diagnostics"] as? NSNumber)?.intValue ?? 0
                let live = (response?["live_sessions"] as? NSNumber)?.intValue ?? 0
                let disconnected = (response?["disconnected_sessions"] as? NSNumber)?.intValue ?? 0
                let status: SetupDiagnosticStatus = !receivedResponse ? .failed
                    : (needingReview > 0 ? .warning : .passed)
                return SetupDiagnosticResult(
                    id: .daemon,
                    status: status,
                    summary: !receivedResponse
                        ? "The daemon connected but did not return valid diagnostics."
                        : (needingReview > 0
                           ? "The daemon is reachable; \(needingReview) session attachment\(needingReview == 1 ? "" : "s") need review."
                           : "The local daemon and current session attachments look healthy."),
                    evidence: [
                        .init("Socket", "Connected at ~/…/focalpoint.sock"),
                        .init("Protocol handshake", receivedResponse ? "Successful" : "No valid response"),
                        .init("Live sessions", "\(live)"),
                        .init("Disconnected sessions", "\(disconnected)"),
                        .init("Attachment warnings", "\(needingReview)")
                    ],
                    actions: [.init(.recheck, title: "Recheck")])
            }.value
        }
    }

    private static func adaptersCheck() -> LocalSetupDiagnosticCheck {
        .init(id: .adapters) {
            await Task.detached {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let config = home.appendingPathComponent(".config/focalpoint/adapters")
                let probes = [
                    ("Claude Code", "hooks.sh", home.appendingPathComponent(".claude/settings.json"),
                     ".config/focalpoint/adapters/hooks.sh"),
                    ("Codex", "codex-hooks.sh", home.appendingPathComponent(".codex/hooks.json"),
                     ".config/focalpoint/adapters/codex-hooks.sh"),
                    ("Cursor", "cursor-hooks.sh", home.appendingPathComponent(".cursor/hooks.json"),
                     ".config/focalpoint/adapters/cursor-hooks.sh"),
                    ("Gemini CLI", "gemini-hooks.sh", home.appendingPathComponent(".gemini/settings.json"),
                     ".config/focalpoint/adapters/gemini-hooks.sh")
                ]
                let evidence = probes.map { provider, script, settings, marker -> SetupDiagnosticEvidence in
                    let scriptURL = config.appendingPathComponent(script)
                    let installed = FileManager.default.isExecutableFile(atPath: scriptURL.path)
                    let markerPresent = fileContainsMarker(settings, marker: marker)
                    let configured: Bool
                    if provider == "Cursor" {
                        configured = markerPresent && cursorSessionStartConfigured(settings, marker: marker)
                    } else if provider == "Gemini CLI" {
                        configured = (try? Data(contentsOf: settings)).map {
                            GeminiHookDiagnostics.sessionStartConfigured($0, marker: marker)
                        } ?? false
                    } else {
                        configured = markerPresent
                    }
                    let value: String
                    if installed && configured { value = "Installed and configured" }
                    else if installed && provider == "Cursor" && markerPresent {
                        value = "Adapter installed; sessionStart hook missing"
                    }
                    else if installed { value = "Adapter installed; hook not configured" }
                    else { value = "Adapter not installed" }
                    return .init(provider, value)
                }
                let ready = evidence.filter { $0.value == "Installed and configured" }.count
                return SetupDiagnosticResult(
                    id: .adapters,
                    status: ready == probes.count ? .passed : (ready > 0 ? .warning : .failed),
                    summary: ready == probes.count
                        ? "All bundled provider adapters are wired into their local hooks."
                        : "\(ready) of \(probes.count) bundled adapters are fully configured.",
                    evidence: evidence,
                    actions: [
                        .init(.copyInstallCommand, title: "Copy safe installer command", isPrimary: ready == 0),
                        .init(.revealFocalPointConfig, title: "Show adapter folder"),
                        .init(.recheck, title: "Recheck")
                    ])
            }.value
        }
    }

    private static func tmuxCheck() -> LocalSetupDiagnosticCheck {
        .init(id: .tmux) {
            await Task.detached {
                let executable = findExecutable("tmux")
                let config = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/focalpoint/tmux.conf")
                let runner = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/focalpoint/focalpoint-run.sh")
                let configPresent = FileManager.default.fileExists(atPath: config.path)
                let runnerPresent = FileManager.default.isExecutableFile(atPath: runner.path)
                let ready = executable != nil && configPresent && runnerPresent
                return SetupDiagnosticResult(
                    id: .tmux,
                    status: ready ? .passed : (executable == nil ? .warning : .failed),
                    summary: ready
                        ? "Managed-session transport is ready."
                        : "tmux is optional, but required for precise managed-session attachment.",
                    evidence: [
                        .init("tmux command", executable == nil ? "Not found on PATH" : "Available"),
                        .init("FocalPoint tmux config", configPresent ? "Present" : "Missing"),
                        .init("Managed launcher", runnerPresent ? "Installed" : "Missing")
                    ],
                    actions: [
                        .init(.copyTmuxInstallCommand, title: "Copy tmux install command",
                              isPrimary: executable == nil),
                        .init(.copyInstallCommand, title: "Copy FocalPoint installer command"),
                        .init(.recheck, title: "Recheck")
                    ])
            }.value
        }
    }

    private static func permissionsCheck() -> LocalSetupDiagnosticCheck {
        .init(id: .permissions) {
            await Task.detached {
                let accessibility = AXIsProcessTrusted()
                let inputMonitoring = CGPreflightListenEventAccess()
                let automation = automationPermissionLabel()
                let hasDenied = automation == "Denied"
                let status: SetupDiagnosticStatus = hasDenied ? .failed
                    : ((!accessibility || !inputMonitoring || automation == "Not requested") ? .warning : .passed)
                return SetupDiagnosticResult(
                    id: .permissions,
                    status: status,
                    summary: status == .passed
                        ? "Optional macOS permissions are available."
                        : "Core menu-bar features work without these permissions; integrations may request them when used.",
                    evidence: [
                        .init("Accessibility (optional)", accessibility ? "Granted" : "Not granted"),
                        .init("Input Monitoring (optional)", inputMonitoring ? "Granted" : "Not granted"),
                        .init("iTerm Automation", automation)
                    ],
                    actions: [
                        .init(.openAccessibilitySettings, title: "Open Privacy settings"),
                        .init(.openAutomationSettings, title: "Open Automation settings"),
                        .init(.recheck, title: "Recheck")
                    ])
            }.value
        }
    }

    private static func loginStartupCheck() -> LocalSetupDiagnosticCheck {
        .init(id: .loginStartup) {
            await Task.detached {
                let home = FileManager.default.homeDirectoryForCurrentUser
                let plist = home.appendingPathComponent("Library/LaunchAgents/dev.focalpoint.daemon.plist")
                let plistPresent = FileManager.default.fileExists(atPath: plist.path)
                let launchdLoaded = commandSucceeded("/bin/launchctl", [
                    "print", "gui/\(getuid())/dev.focalpoint.daemon"
                ])
                let appStatus = await MainActor.run { loginItemLabel(SMAppService.mainApp.status) }
                let ready = plistPresent && launchdLoaded
                return SetupDiagnosticResult(
                    id: .loginStartup,
                    status: ready && appStatus == "Enabled" ? .passed : (ready ? .warning : .failed),
                    summary: ready
                        ? "The daemon is configured to start at login."
                        : "The daemon launch agent is missing or not loaded.",
                    evidence: [
                        .init("Daemon LaunchAgent", plistPresent ? "Installed" : "Missing"),
                        .init("Daemon launchd job", launchdLoaded ? "Loaded" : "Not loaded"),
                        .init("Menu-bar app login item", appStatus)
                    ],
                    actions: [
                        .init(.startDaemon, title: "Start daemon", isPrimary: !launchdLoaded),
                        .init(.copyInstallCommand, title: "Copy installer command"),
                        .init(.enableAppLogin, title: "Enable app at login", isPrimary: ready && appStatus != "Enabled"),
                        .init(.openLoginItemsSettings, title: "Open Login Items"),
                        .init(.recheck, title: "Recheck")
                    ])
            }.value
        }
    }

    private static func providersCheck() -> LocalSetupDiagnosticCheck {
        .init(id: .providers) {
            await Task.detached {
                let providers = [
                    ("Claude Code", [("claude", ["auth", "status", "--json"])]),
                    ("Codex", [("codex", ["login", "status"])]),
                    ("Cursor", [
                        ("cursor-agent", ["status", "--format", "json"]),
                        ("cursor", ["agent", "status", "--format", "json"])
                    ]),
                    // Gemini has no noninteractive authentication-status
                    // command. Presence alone must not claim authenticated.
                    ("Gemini CLI", [("gemini", [])])
                ]
                let checkableCount = providers.filter { provider in
                    provider.1.contains { !$0.1.isEmpty }
                }.count
                var installedCount = 0
                var authenticatedCount = 0
                let evidence = providers.map { name, commands -> SetupDiagnosticEvidence in
                    guard let candidate = commands.compactMap({ command, arguments in
                        findExecutable(command).map { ($0, arguments) }
                    }).first else {
                        return .init(name, "CLI not found")
                    }
                    installedCount += 1
                    guard !candidate.1.isEmpty else {
                        return .init(name, "CLI installed; authentication not checked. Sign in from Gemini.")
                    }
                    let authenticated = commandSucceeded(candidate.0.path, candidate.1, timeout: 4)
                    if authenticated { authenticatedCount += 1 }
                    return .init(name, authenticated
                                 ? "CLI installed; authentication verified"
                                 : "CLI installed; authentication not verified")
                }
                return SetupDiagnosticResult(
                    id: .providers,
                    status: authenticatedCount == checkableCount && installedCount == providers.count ? .passed
                        : (installedCount > 0 ? .warning : .failed),
                    summary: installedCount > 0
                        ? "\(installedCount) of \(providers.count) provider CLIs installed; authentication verified for \(authenticatedCount) of \(checkableCount) checkable providers."
                        : "No supported provider CLI was found on PATH.",
                    evidence: evidence,
                    actions: [
                        .init(.openProviderSetupGuide, title: "Open provider setup guide",
                              isPrimary: authenticatedCount == 0),
                        .init(.recheck, title: "Recheck")
                    ])
            }.value
        }
    }
}

struct LocalSetupDiagnosticActionPerformer: SetupDiagnosticActionPerforming {
    func perform(_ action: SetupDiagnosticAction) async -> SetupDiagnosticActionOutcome {
        switch action.kind {
        case .recheck:
            return .init(succeeded: true, message: "Running the check again…", shouldRecheck: true)
        case .copyInstallCommand:
            return await copy("./install.sh", message: "Copied ./install.sh. Run it from a trusted FocalPoint checkout.")
        case .copyTmuxInstallCommand:
            return await copy("brew install tmux", message: "Copied brew install tmux.")
        case .openAccessibilitySettings:
            return await openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                                 success: "Opened System Settings.")
        case .openAutomationSettings:
            return await openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
                                 success: "Opened System Settings.")
        case .openLoginItemsSettings:
            return await openURL("x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
                                 success: "Opened System Settings.")
        case .revealFocalPointConfig:
            return await MainActor.run {
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".config/focalpoint/adapters", isDirectory: true)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return .init(succeeded: true, message: "Opened the FocalPoint adapter folder.")
            }
        case .openProviderSetupGuide:
            return await openURL("https://github.com/tchamp1912/FocalPoint#install",
                                 success: "Opened the provider setup guide.")
        case .startDaemon:
            let ok = await Task.detached {
                commandSucceeded("/bin/launchctl", ["kickstart", "gui/\(getuid())/dev.focalpoint.daemon"])
            }.value
            return .init(succeeded: ok,
                         message: ok ? "Asked launchd to start the daemon." : "launchd could not start the daemon.",
                         shouldRecheck: ok)
        case .enableAppLogin:
            return await MainActor.run {
                do {
                    try SMAppService.mainApp.register()
                    return .init(succeeded: true, message: "Enabled FocalPoint at login.", shouldRecheck: true)
                } catch {
                    return .init(succeeded: false, message: "Could not enable the login item. Open Login Items to review it.")
                }
            }
        }
    }

    @MainActor
    private func copy(_ value: String, message: String) -> SetupDiagnosticActionOutcome {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        return .init(succeeded: true, message: message)
    }

    @MainActor
    private func openURL(_ value: String, success: String) -> SetupDiagnosticActionOutcome {
        guard let url = URL(string: value), NSWorkspace.shared.open(url) else {
            return .init(succeeded: false, message: "Could not open the requested page.")
        }
        return .init(succeeded: true, message: success)
    }
}

private func findExecutable(_ name: String) -> URL? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    for directory in path.split(separator: ":") {
        let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
    }
    return nil
}

private func fileContainsMarker(_ url: URL, marker: String) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 2 * 1024 * 1024),
          let text = String(data: data, encoding: .utf8) else { return false }
    return text.contains(marker)
}

private func cursorSessionStartConfigured(_ url: URL, marker: String) -> Bool {
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hooks = root["hooks"] as? [String: Any],
          let entries = hooks["sessionStart"] as? [[String: Any]] else { return false }
    return entries.contains { entry in
        (entry["command"] as? String)?.contains(marker) == true
    }
}

private func commandSucceeded(_ executable: String, _ arguments: [String],
                              timeout: TimeInterval = 3) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

private func automationPermissionLabel() -> String {
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil else {
        return "iTerm not installed"
    }
    let descriptor = NSAppleEventDescriptor(bundleIdentifier: "com.googlecode.iterm2")
    let status = AEDeterminePermissionToAutomateTarget(descriptor.aeDesc,
                                                       typeWildCard,
                                                       typeWildCard,
                                                       false)
    return switch status {
    case noErr: "Granted"
    case OSStatus(errAEEventNotPermitted): "Denied"
    case -1744: "Not requested"
    default: "Not requested"
    }
}

@MainActor
private func loginItemLabel(_ status: SMAppService.Status) -> String {
    switch status {
    case .enabled: "Enabled"
    case .requiresApproval: "Needs approval"
    case .notRegistered: "Not enabled"
    case .notFound: "Unavailable for this app copy"
    @unknown default: "Unknown"
    }
}
