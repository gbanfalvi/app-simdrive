import Synchronization

/// Values by token, safe to read from any thread, as callbacks of a private framework that names their caller by token.
final class TokenRegistry<Value: Sendable>: Sendable {
    private let values = Mutex<[String: Value]>([:])

    func register(_ value: Value, for token: String) {
        values.withLock { $0[token] = value }
    }

    /// Removes the token's value if `isOwn` says it is still the caller's, not one registered for the token since.
    func remove(_ token: String, ifOwn isOwn: (Value) -> Bool) {
        values.withLock { values in
            if let value = values[token], isOwn(value) { values[token] = nil }
        }
    }

    func value(for token: String) -> Value? {
        values.withLock { $0[token] }
    }

    /// The value when exactly one is registered, for a callback that names no token.
    var onlyValue: Value? {
        values.withLock { $0.count == 1 ? $0.first?.value : nil }
    }
}
