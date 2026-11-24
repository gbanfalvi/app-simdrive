import Synchronization

/// Waits until `start` calls its completion, or throws `timeout` after `limit`. The work itself is not stopped.
@MainActor
package func waitForCompletion<Value: Sendable>(within limit: Duration, timeout: SimDriveError,
                                        _ start: (@escaping @Sendable (Value) -> Void) -> Void) async throws -> Value {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
        let resumption = SingleResumption(continuation)
        start { resumption.resume(with: .success($0)) }
        Task {
            try? await Task.sleep(for: limit)
            resumption.resume(with: .failure(timeout))
        }
    }
}

/// Runs `operation` on the main actor, or throws `timeout` after `limit`. The operation keeps running after a timeout,
/// since a private framework's call cannot be stopped, and its result is dropped.
@MainActor
func withTimeLimit<Value>(_ limit: Duration, timeout: SimDriveError,
                          _ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
    let run = Task { @MainActor in MainActorValue(try await operation()) }
    return try await waitForCompletion(within: limit, timeout: timeout) { done in
        Task { done(await run.result) }
    }.get().value
}

/// Carries a value between main-actor tasks, since a `Task`'s result must be `Sendable`. It never leaves the main actor.
struct MainActorValue<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}

/// Resumes a continuation once, from whichever producer finishes first.
private final class SingleResumption<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<Value, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}
