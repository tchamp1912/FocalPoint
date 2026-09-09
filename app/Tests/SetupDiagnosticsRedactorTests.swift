import Foundation

@main
enum SetupDiagnosticsRedactorTests {
    static func main() {
        let home = NSHomeDirectory()
        let input = """
        [session] upsert id=abc title=private customer prompt task_id=worker-1 cwd=\(home)/Secret Project adapter_event=sessionStart
        access_token=top-secret-value user@example.com Bearer abcdefghijklmnop
        """
        let redacted = SetupDiagnosticsRedactor.redact(input, limit: 20_000)
        precondition(!redacted.contains("private customer prompt"))
        precondition(!redacted.contains("Secret Project"))
        precondition(!redacted.contains("top-secret-value"))
        precondition(!redacted.contains("user@example.com"))
        precondition(!redacted.contains("abcdefghijklmnop"))
        precondition(redacted.contains("title=[REDACTED]"))
        precondition(redacted.contains("cwd=[REDACTED]"))

        let long = String(repeating: "safe-status-line\n", count: 200)
        precondition(SetupDiagnosticsRedactor.redact(long, limit: 50_000).count > 1_000,
                     "support reports must not inherit the short UI-field limit")
        print("SetupDiagnosticsRedactorTests: PASS")
    }
}
