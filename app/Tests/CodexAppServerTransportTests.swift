import Foundation
import Darwin

@main
enum CodexAppServerTransportTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Keep SIGPIPE at its default disposition: a missed per-fd guard
        // terminates this test process instead of being hidden by the runner.
        signal(SIGPIPE, SIG_DFL)
        func script(_ name: String, _ body: String) throws -> URL {
            let path = root.appendingPathComponent(name)
            try ("#!/usr/bin/python3\nimport sys,os,time,json,signal\n" + body).write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
            return path
        }
        func run(_ name: String, _ body: String, timeout: Double = 0.4,
                 limit: Int = 65_536) throws -> Result<[String: Any], CodexAppServerFailure> {
            let path = try script(name, "open(__file__+'.pid','w').write(str(os.getpid()))\n" + body)
            let start = ProcessInfo.processInfo.systemUptime
            let result = CodexAppServerTransport.readRateLimits(executable: path, timeout: timeout, maxOutputBytes: limit)
            precondition(ProcessInfo.processInfo.systemUptime - start < timeout + 1.5, "bounded completion: \(name)")
            if let recorded = try? String(contentsOfFile: path.path + ".pid", encoding: .utf8), let pid = Int32(recorded) {
                precondition(kill(pid, 0) == -1 && errno == ESRCH, "child must be gone after return: \(name)")
            }
            return result
        }
        func failure(_ result: Result<[String: Any], CodexAppServerFailure>, _ expected: CodexAppServerFailure? = nil) {
            guard case .failure(let value) = result else { fatalError("expected transport failure") }
            if let expected { precondition(value == expected, "expected \(expected), got \(value)") }
        }
        failure(try run("warmup", "sys.exit(0)\n"))
        let descriptorsBefore = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        for index in 0..<12 {
            failure(try run("exit-\(index)", "sys.exit(0)\n"))
        }
        let descriptorsAfter = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        precondition(descriptorsAfter <= descriptorsBefore + 1, "repeated launches must not leak pipe descriptors")
        failure(try run("closed-input", """
        first=json.loads(sys.stdin.readline())
        os.close(0)
        print(json.dumps({'id':0,'result':{}}),flush=True)
        time.sleep(3)
        """), .inputClosed)
        let valid = try run("valid", """
        first=json.loads(sys.stdin.readline())
        assert first['method']=='initialize'
        print(json.dumps({'id':0,'result':{}}),flush=True)
        assert json.loads(sys.stdin.readline())['method']=='initialized'
        assert json.loads(sys.stdin.readline())['method']=='account/rateLimits/read'
        sys.stderr.write('PRIVATE ACCOUNT DATA' * 20000)
        sys.stderr.flush()
        print(json.dumps({'method':'notification','params':{}}),flush=True)
        print(json.dumps({'id':1,'result':{'rateLimits':{'primary':{'usedPercent':25}}}}),flush=True)
        time.sleep(3)
        """, timeout: 2)
        guard case .success(let limits) = valid else { fatalError("valid handshake should return rate limits") }
        precondition((limits["primary"] as? [String: Any])?["usedPercent"] as? Int == 25)
        failure(try run("stall", "time.sleep(3)\n"), .timedOut)
        failure(try run("stalled-request", "sys.stdin.readline();print(json.dumps({'id':0,'result':{}}),flush=True);time.sleep(3)\n"), .timedOut)
        failure(try run("partial-line", "sys.stdout.write('{');sys.stdout.flush();time.sleep(3)\n"), .timedOut)
        failure(try run("oversized", "sys.stdout.write('x'*100000);sys.stdout.flush();time.sleep(3)\n", limit: 1024), .outputLimit)
        failure(try run("ignores-term", "signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(3)\n"), .timedOut)
        failure(try run("rpc-error", "sys.stdin.readline();print(json.dumps({'id':0,'error':{'message':'PRIVATE ACCOUNT DATA'}}),flush=True)\n"), .rpcError)
        let customBin = root.appendingPathComponent("custom-bin")
        try FileManager.default.createDirectory(at: customBin, withIntermediateDirectories: true)
        let codex = customBin.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        precondition(CodexAppServerTransport.executable(environment: ["PATH": customBin.path], homeDirectory: root) == codex)
        let directories = CodexAppServerTransport.executableDirectories(environment: ["PATH": "/usr/bin:/bin"], homeDirectory: root)
        precondition(directories.contains("/opt/homebrew/bin"))
        precondition(directories.contains(root.appendingPathComponent(".local/bin").path))
        precondition(Set(directories).count == directories.count)
        print("CodexAppServerTransportTests: PASS")
    }
}
