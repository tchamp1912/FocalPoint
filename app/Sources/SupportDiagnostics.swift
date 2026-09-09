// FocalPoint support bundle — bounded, redacted operational diagnostics.
// MIT License.

import Foundation

enum SupportDiagnosticsReport {
    private static let repository = "https://github.com/tchamp1912/FocalPoint"
    private static let maxLogBytes: UInt64 = 160 * 1024
    private static let maxLogLines = 300

    static func collect(setupResults: [SetupDiagnosticResult], generatedAt: Date = Date()) -> String {
        let daemonSnapshot = collectDaemonSnapshot()
        var sections = [
            SetupDiagnosticsReport.text(results: setupResults, generatedAt: generatedAt),
            "",
            "FocalPoint runtime diagnostics",
            daemonSnapshot,
            "",
            "Recent redacted operational logs",
            "Only lifecycle, attachment, probe, focus, launch, and connection lines are included.",
            "Prompts, transcripts, tool input/output, titles, labels, and working directories are excluded."
        ]
        for source in logSources() {
            let tail = safeLogTail(source.url)
            guard !tail.isEmpty else { continue }
            sections.append("")
            sections.append("--- \(source.name) ---")
            sections.append(tail)
        }
        return SetupDiagnosticsRedactor.redact(sections.joined(separator: "\n"), limit: 220_000)
    }

    static func issueURL(report: String) -> URL? {
        guard var components = URLComponents(string: repository + "/issues/new") else { return nil }
        let excerpt: String
        if report.count <= 5_000 {
            excerpt = report
        } else {
            excerpt = String(report.prefix(2_500))
                + "\n\n[… middle omitted from URL; full report is on the clipboard …]\n\n"
                + String(report.suffix(2_500))
        }
        let body = """
        ### What happened
        <!-- Describe what you expected and what happened instead. -->

        ### Redacted diagnostics
        The FocalPoint app copied the complete redacted report to the clipboard. A bounded excerpt is included below.

        ```text
        \(excerpt)
        ```
        """
        components.queryItems = [
            URLQueryItem(name: "title", value: "Bug: session attachment, focus, or disconnect"),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: "bug")
        ]
        return components.url
    }

    private static func collectDaemonSnapshot() -> String {
        let client = DaemonClient()
        guard let snapshot = client.request(["cmd": "get-diagnostics"], timeout: 2),
              let data = try? JSONSerialization.data(withJSONObject: snapshot,
                                                     options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "Daemon diagnostics were unavailable."
        }
        return SetupDiagnosticsRedactor.redact(text, limit: 80_000)
    }

    private static func logSources() -> [(name: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let libraryLogs = home.appendingPathComponent("Library/Logs/focalpoint", isDirectory: true)
        let stateRoot = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".local/state", isDirectory: true)
        return [
            ("daemon", libraryLogs.appendingPathComponent("focalpointd.err.log")),
            ("app", libraryLogs.appendingPathComponent("FocalPoint.app.log")),
            ("cursor hook", stateRoot.appendingPathComponent("focalpoint/logs/cursor-hooks.log"))
        ]
    }

    private static func safeLogTail(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxLogBytes ? size - maxLogBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else { return "" }
        if offset > 0, let newline = text.firstIndex(of: "\n") {
            text.removeSubrange(...newline)
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { isOperationalLine(String($0)) }
            .suffix(maxLogLines)
            .map { SetupDiagnosticsRedactor.redact(String($0), limit: 2_000) }
        return lines.joined(separator: "\n")
    }

    private static func isOperationalLine(_ line: String) -> Bool {
        ["[cursor-hook]", "[focalpoint-app]", "[session-input]", "[session]",
         "[probe]", "[focus]", "[focus-action]", "[managed-launch]",
         "[managed-relaunch]", "[snapshot]", "[channel]", "[daemon]"]
            .contains { line.contains($0) }
    }
}
