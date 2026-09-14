// swiftc -parse-as-library Sources/SafeLocalIO.swift Sources/DaemonTransport.swift
//   Tests/DaemonTransportTests.swift -o /tmp/focalpoint-transport-tests
import Foundation
import Darwin

@main
enum DaemonTransportTests {
    static func main() throws {
        if CommandLine.arguments.count > 1 {
            // Each case runs with the default disposition in a separate process:
            // a regression kills the child and produces a test failure, not a hang.
            signal(SIGPIPE, SIG_DFL)
            runChild(CommandLine.arguments[1])
            return
        }
        for mode in ["closed-daemon", "closed-stderr", "closed-pipe", "healthy-socket", "unprotected-control"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [mode]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            if mode == "unprotected-control" {
                precondition(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGPIPE,
                             "negative control must prove SIGPIPE is enabled")
            } else {
                precondition(child.terminationReason == .exit && child.terminationStatus == 0,
                             "\(mode) exited unexpectedly: \(child.terminationReason) / \(child.terminationStatus)")
            }
        }
        print("DaemonTransportTests: PASS (protected sockets, pipes, stderr; SIGPIPE control)")
    }

    static func runChild(_ mode: String) {
        if mode == "closed-daemon" {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fp-sock-\(UUID().uuidString.prefix(8))")
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            setenv("XDG_RUNTIME_DIR", directory.path, 1)
            let server = socket(AF_UNIX, SOCK_STREAM, 0)
            precondition(server >= 0)
            defer { close(server) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(focalpointSocketPath().utf8)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                precondition(bytes.count < buffer.count)
                for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            precondition(bound == 0 && listen(server, 1) == 0)
            guard let client = focalpointConnect(recvTimeout: 1) else { fatalError("test daemon connect failed") }
            defer { close(client) }
            let peer = accept(server, nil, nil)
            precondition(peer >= 0)
            close(peer)
            var byte: UInt8 = 0
            precondition(read(client, &byte, 1) == 0, "peer closure must precede the write")
            precondition(!focalpointSendLine(client, "{\"cmd\":\"subscribe\"}"))
        } else if mode == "healthy-socket" {
            var sockets = [Int32](repeating: -1, count: 2)
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
            defer { sockets.forEach { close($0) } }
            precondition(focalpointSendLine(sockets[0], "hello"))
            var bytes = [UInt8](repeating: 0, count: 6)
            precondition(read(sockets[1], &bytes, bytes.count) == 6)
            precondition(String(bytes: bytes, encoding: .utf8) == "hello\n")
        } else {
            var descriptors = [Int32](repeating: -1, count: 2)
            precondition(pipe(&descriptors) == 0)
            close(descriptors[0])
            defer { close(descriptors[1]) }
            if mode == "closed-stderr" {
                precondition(dup2(descriptors[1], STDERR_FILENO) == STDERR_FILENO)
                precondition(!focalpointWriteSafely(Data("diagnostic".utf8), to: .standardError))
            } else if mode == "closed-pipe" {
                let handle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: false)
                precondition(!focalpointWriteSafely(Data("request".utf8), to: handle))
                precondition(!focalpointSuppressSIGPIPE(-1))
            } else {
                var byte: UInt8 = 1
                _ = write(descriptors[1], &byte, 1)
                fatalError("default SIGPIPE unexpectedly survived")
            }
        }
    }
}
