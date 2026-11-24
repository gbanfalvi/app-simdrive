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

    /// Takes the lock without waiting and keeps it until the process exits, returning false when another holder has it.
    func holdForLife() -> Bool {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, Self.mode)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        // The descriptor stays open on purpose: the kernel releases the lock when the process exits, however it exits.
        return true
    }
}
