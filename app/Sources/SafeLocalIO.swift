// Broken local pipes are recoverable I/O failures, never app termination.
// Suppress SIGPIPE per descriptor so child processes retain normal signal behavior.
import Foundation
import Darwin

@discardableResult
func focalpointSuppressSIGPIPE(_ fd: Int32) -> Bool {
    fcntl(fd, F_SETNOSIGPIPE, 1) == 0
}

/// Best-effort writes for diagnostics. The caller can continue when the
/// destination was closed or does not support per-descriptor protection.
@discardableResult
func focalpointWriteSafely(_ data: Data, to handle: FileHandle) -> Bool {
    guard focalpointSuppressSIGPIPE(handle.fileDescriptor) else { return false }
    do {
        try handle.write(contentsOf: data)
        return true
    } catch {
        return false
    }
}
