import Foundation

@main
enum GeminiPresentationTests {
    static func main() throws {
        let provider = try JSONDecoder().decode(HistoryProvider.self, from: Data("\"gemini\"".utf8))
        precondition(provider.displayName == "Gemini")
        precondition(provider.supportsResume)
        precondition(HistoryProvider.allCases.contains(.gemini))
        precondition(provider.resumeCommand(sessionID: "session-123") == "gemini --resume 'session-123'")
        precondition(provider.resumeCommand(sessionID: "one'two") == "gemini --resume 'one'\\''two'")
        precondition(HistoryProvider.cursor.resumeCommand(sessionID: "chat") == nil)
        precondition(HistoryProvider.codex.resumeCommand(sessionID: "old") == "codex resume 'old'")

        let marker = ".config/focalpoint/adapters/gemini-hooks.sh"
        func configured(_ extra: String = "", hook: String? = nil) -> Bool {
            let command = hook ?? "{\"name\":\"focalpoint\",\"type\":\"command\",\"command\":\"$HOME/\(marker)\"}"
            let json = "{\"hooks\":{\"SessionStart\":[{\"hooks\":[\(command)]}]}\(extra)}"
            return GeminiHookDiagnostics.sessionStartConfigured(Data(json.utf8), marker: marker)
        }
        precondition(configured())
        precondition(!configured(",\"hooksConfig\":{\"enabled\":false}"))
        precondition(!configured(",\"hooksConfig\":{\"disabled\":[\"focalpoint\"]}"))
        precondition(!configured(hook: "{\"type\":\"command\",\"command\":\"echo unrelated\"}"))
        precondition(!GeminiHookDiagnostics.sessionStartConfigured(Data("{}".utf8), marker: marker))
        let commented = """
        {
          // Gemini allows comments in settings.json.
          "hooks": { "SessionStart": [{ "hooks": [{
            "name": "focalpoint", "type": "command",
            "command": "$HOME/\(marker)"
          }] }] },
          /* A comment between settings is valid too. */
          "hooksConfig": { "enabled": true },
          "example": "https://example.test/*literal*/"
        }
        """
        precondition(GeminiHookDiagnostics.sessionStartConfigured(Data(commented.utf8), marker: marker))
        let disabled = commented.replacingOccurrences(of: "\"enabled\": true", with: "\"enabled\": false")
        precondition(!GeminiHookDiagnostics.sessionStartConfigured(Data(disabled.utf8), marker: marker))
        precondition(!GeminiHookDiagnostics.sessionStartConfigured(Data((commented + " /* unclosed").utf8), marker: marker))
        print("Gemini history and setup diagnostics tests passed")
    }
}
