// Bounded Codex app-server stdio exchange. No account data is logged here.
// Foundation-only apart from Darwin's per-descriptor and poll/read/write APIs.
import Foundation
import Darwin

enum CodexAppServerFailure: String, Error {
    case unavailable, launchFailed, pipeSetupFailed, inputClosed, outputClosed
    case timedOut, outputLimit, rpcError, invalidResponse
}

enum CodexAppServerTransport {
    static func executable(environment: [String: String] = ProcessInfo.processInfo.environment,
                           homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        for directory in executableDirectories(environment: environment, homeDirectory: homeDirectory) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func executableDirectories(environment: [String: String], homeDirectory: URL) -> [String] {
        let candidates = (environment["PATH"] ?? "").split(separator: ":").map(String.init) + [
            homeDirectory.appendingPathComponent(".local/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            homeDirectory.appendingPathComponent(".cargo/bin").path,
        ]
        var seen: Set<String> = []
        return candidates.filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    static func readRateLimits(executable: URL, timeout: TimeInterval = 5,
                               maxOutputBytes: Int = 262_144) -> Result<[String: Any], CodexAppServerFailure> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = executableDirectories(environment: environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser).joined(separator: ":")
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Diagnostics can contain account information. Discard stderr rather
        // than leaving an undrained pipe that can block the child forever.
        process.standardError = FileHandle.nullDevice
        defer {
            try? input.fileHandleForWriting.close()
            try? input.fileHandleForReading.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let gracefulDeadline = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < gracefulDeadline { usleep(10_000) }
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                let killDeadline = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { usleep(10_000) }
            }
        }
        let writeFD = input.fileHandleForWriting.fileDescriptor
        let readFD = output.fileHandleForReading.fileDescriptor
        guard timeout.isFinite, timeout > 0, maxOutputBytes > 0,
              focalpointSuppressSIGPIPE(writeFD), nonblocking(writeFD), nonblocking(readFD) else {
            return .failure(.pipeSetupFailed)
        }
        do { try process.run() } catch { return .failure(.launchFailed) }
        // Parent copies of the child ends must close so an exited child
        // produces EOF/EPIPE immediately, instead of looking alive forever.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let exchange = Exchange(writeFD: writeFD, readFD: readFD,
                                deadline: ProcessInfo.processInfo.systemUptime + timeout,
                                maxOutputBytes: maxOutputBytes)
        do {
            try exchange.send(["method": "initialize", "id": 0,
                "params": ["clientInfo": ["name": "focalpoint", "title": "FocalPoint", "version": "0.1"]]])
            _ = try exchange.response(id: 0)
            try exchange.send(["method": "initialized", "params": [:]])
            try exchange.send(["method": "account/rateLimits/read", "id": 1])
            let result = try exchange.response(id: 1)
            guard let limits = result["rateLimits"] as? [String: Any] else { return .failure(.invalidResponse) }
            return .success(limits)
        } catch let failure as CodexAppServerFailure {
            return .failure(failure)
        } catch {
            return .failure(.invalidResponse)
        }
    }

    private static func nonblocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private final class Exchange {
        let writeFD: Int32
        let readFD: Int32
        let deadline: TimeInterval
        let maxOutputBytes: Int
        var receivedBytes = 0
        var buffered = Data()

        init(writeFD: Int32, readFD: Int32, deadline: TimeInterval, maxOutputBytes: Int) {
            self.writeFD = writeFD; self.readFD = readFD
            self.deadline = deadline; self.maxOutputBytes = maxOutputBytes
        }

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try wait(fd: writeFD, events: Int16(POLLOUT))
                    let written = Darwin.write(writeFD, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if written > 0 { offset += written }
                    else if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    else { throw CodexAppServerFailure.inputClosed }
                }
            }
        }

        func response(id: Int) throws -> [String: Any] {
            while true {
                while let newline = buffered.firstIndex(of: 0x0A) {
                    let line = buffered.prefix(upTo: newline)
                    buffered.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          (object["id"] as? NSNumber)?.intValue == id else { continue }
                    if object["error"] != nil { throw CodexAppServerFailure.rpcError }
                    guard let result = object["result"] as? [String: Any] else { throw CodexAppServerFailure.invalidResponse }
                    return result
                }
                try wait(fd: readFD, events: Int16(POLLIN))
                var chunk = [UInt8](repeating: 0, count: min(8192, maxOutputBytes - receivedBytes) + 1)
                let count = Darwin.read(readFD, &chunk, chunk.count)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw CodexAppServerFailure.outputClosed }
                receivedBytes += count
                guard receivedBytes <= maxOutputBytes else { throw CodexAppServerFailure.outputLimit }
                buffered.append(contentsOf: chunk.prefix(count))
            }
        }

        private func wait(fd: Int32, events: Int16) throws {
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw CodexAppServerFailure.timedOut }
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let status = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
                if status < 0 && errno == EINTR { continue }
                if status == 0 { throw CodexAppServerFailure.timedOut }
                guard status > 0 && descriptor.revents & Int16(POLLNVAL) == 0 else {
                    throw CodexAppServerFailure.pipeSetupFailed
                }
                // HUP/ERR also wake the caller: read returns EOF and write
                // returns EPIPE, with SIGPIPE suppressed only on this pipe.
                return
            }
        }
    }
}
