// Local daemon socket transport, separate from presentation and client models.
import Foundation
import Darwin

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
    var noSigPipe: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                     socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        close(fd)
        return nil
    }
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

@discardableResult
func focalpointSendLine(_ fd: Int32, _ line: String) -> Bool {
    let data = Array((line + "\n").utf8)
    return data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return true }
        var written = 0
        while written < raw.count {
            let n = write(fd, base.advanced(by: written), raw.count - written)
            if n > 0 {
                written += n
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
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

