import Synchronization

/// Waits until `start` calls its completion, or throws `timeout` after `limit`. The work itself is not stopped.
@MainActor
func waitForCompletion<Value: Sendable>(within limit: Duration, timeout: SimDriveError,
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
