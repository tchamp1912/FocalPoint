// FocalPoint menu-bar app — focalpointd unix-socket NDJSON client.
// Reuses the pattern from adapters/mac-virtual/backlight.swift:
// socketPath resolution, connect, sendLine, readLines.
// MIT License.

import Foundation

// MARK: - Socket helpers (PROTOCOL.md §3 transport)

func focalpointSocketPath() -> String {
    if let dir = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !dir.isEmpty {
        return dir + "/focalpoint.sock"
    }
    return NSHomeDirectory() + "/.local/state/focalpoint/focalpoint.sock"
}

/// Connect to the daemon's unix socket. Returns the fd, or nil.
/// `recvTimeout` (seconds, >0) sets SO_RCVTIMEO so one-shot reads never hang.
func focalpointConnect(recvTimeout: Double = 0) -> Int32? {
    let path = focalpointSocketPath()
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let ok = withUnsafeMutableBytes(of: &addr.sun_path) { buf -> Bool in
        let bytes = Array(path.utf8)
        guard bytes.count < buf.count else { return false }
        for (i, b) in bytes.enumerated() { buf[i] = b }
        return true
    }
    guard ok else { close(fd); return nil }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let res = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    guard res == 0 else { close(fd); return nil }
    if recvTimeout > 0 {
        var tv = timeval(tv_sec: Int(recvTimeout),
                         tv_usec: __darwin_suseconds_t((recvTimeout - Double(Int(recvTimeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    return fd
}

func focalpointSendLine(_ fd: Int32, _ line: String) {
    let data = Array((line + "\n").utf8)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

/// Read NDJSON objects from fd, invoking handler per object. Returns on EOF/error.
func focalpointReadLines(_ fd: Int32, handler: ([String: Any]) -> Bool) {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return }
        buffer.append(contentsOf: chunk[0..<n])
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: nl)
            buffer.removeSubrange(...nl)
            if let obj = try? JSONSerialization.jsonObject(with: Data(lineData)),
               let dict = obj as? [String: Any] {
                if !handler(dict) { return }
            }
        }
    }
}

func focalpointEncode(_ obj: [String: Any]) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: data, encoding: .utf8) else { return nil }
    return s
}

// MARK: - Client

/// Owns the long-lived subscribe stream (background thread, auto-reconnect)
/// plus one-shot request/command connections. All callbacks fire on a
/// background thread; the model marshals them to the main actor.
final class DaemonClient {
    private var running = false
    private let lock = NSLock()

    /// Start the subscribe loop. Reconnects every 2 s while down.
    /// onStatus(up) fires on every connect/disconnect edge.
    /// onConnect fires once per successful connect (before events stream),
    /// so the model can issue one-shot get-styles / list-sessions refreshes.
    func startSubscribe(onStatus: @escaping (Bool) -> Void,
                        onConnect: @escaping () -> Void,
                        onEvent: @escaping ([String: Any]) -> Void) {
        lock.lock(); running = true; lock.unlock()
        Thread.detachNewThread {
            while self.isRunning {
                if let fd = focalpointConnect() {
                    log("connected to focalpointd")
                    onStatus(true)
                    onConnect()
                    guard let sub = focalpointEncode(["cmd": "subscribe"]) else { close(fd); continue }
                    focalpointSendLine(fd, sub)
                    focalpointReadLines(fd) { obj in
                        onEvent(obj)
                        return self.isRunning
                    }
                    close(fd)
                    onStatus(false)
                    log("daemon connection lost; retrying")
                }
                if self.isRunning { Thread.sleep(forTimeInterval: 2) }
            }
        }
    }

    private var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }; return running
    }

    func stop() { lock.lock(); running = false; lock.unlock() }

    /// One-shot request: connect, send, read the first response object, close.
    /// Runs synchronously on the calling thread; call from a background queue.
    func request(_ obj: [String: Any], timeout: Double = 1.0) -> [String: Any]? {
        guard let fd = focalpointConnect(recvTimeout: timeout),
              let line = focalpointEncode(obj) else { return nil }
        defer { close(fd) }
        focalpointSendLine(fd, line)
        var result: [String: Any]?
        focalpointReadLines(fd) { dict in
            result = dict
            return false   // stop after first line (the response)
        }
        return result
    }

    /// Fire-and-forget command on its own short-lived connection.
    func send(_ obj: [String: Any]) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = self.request(obj, timeout: 1.0)
        }
    }
}

func log(_ msg: String) {
    FileHandle.standardError.write(Data("[focalpoint] \(msg)\n".utf8))
}
