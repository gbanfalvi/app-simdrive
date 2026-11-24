import Darwin
import Foundation

/// An advisory lock on a file of its own, shared by every simdrive process of this user.
struct FileLock: Sendable {
    static let pathExtension = "lock"
    private static let mode: mode_t = 0o600

    let url: URL

    /// Runs `body` while holding the lock, waiting for other holders. Runs it unlocked if the lock file cannot be opened,
    /// since a missing lock only risks a lost update, which the callers already tolerate.
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, Self.mode)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0, errno == EINTR {}
        return try body()
    }
}
