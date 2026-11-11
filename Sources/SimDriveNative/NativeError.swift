import Foundation
import Synchronization

/// A failure of a private framework or guest service, named by a stable identifier.
package struct NativeError: LocalizedError, Equatable, Sendable {
    package let identifier: String
    package let message: String

    package init(_ identifier: String, _ message: String) {
        self.identifier = identifier
        self.message = message
    }

    package var errorDescription: String? { message }
}

/// Resumes a continuation once, from whichever producer finishes first.
final class SingleResumption<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, any Error>?>

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<Value, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}

/// Waits until `start` calls its completion, or throws `timeout` after `limit`. The work itself is not stopped.
@MainActor
func waitForCompletion(within limit: Duration, timeout: NativeError,
                       _ start: (@escaping @Sendable () -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let resumption = SingleResumption(continuation)
        start { resumption.resume(with: .success(())) }
        Task {
            try? await Task.sleep(for: limit)
            resumption.resume(with: .failure(timeout))
        }
    }
}
