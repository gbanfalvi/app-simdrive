import Foundation

/// Runs `operation` until it finishes or `limit` passes, whichever comes first, and returns its value, or nil past the
/// limit. Past the limit the operation is cancelled and this returns at once, even if the operation ignores
/// cancellation, as a guest's XPC call does; its eventual result is dropped. When the caller is cancelled, so is the
/// operation, and this throws `CancellationError`. No timer outlives the call.
@MainActor
func withDeadline<Value>(_ limit: Duration, _ operation: @escaping @MainActor () async throws -> Value) async throws -> Value? {
    let race = DeadlineRace<Value>()
    let outcome = await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<MainActorBox<DeadlineRace<Value>.Outcome>, Never>) in
            race.start(continuation, limit: limit, operation: operation)
        }
    } onCancel: {
        Task { @MainActor in race.finish(.cancelled) }
    }
    switch outcome.value {
    case .finished(let result): return try result.get()
    case .timedOut: return nil
    case .cancelled: throw CancellationError()
    }
}

/// Repeats `check` every `interval` until it returns a value, and returns that value, or nil once `limit` passes.
///
/// By default the limit also bounds a check in progress, which is cancelled. With `finishingChecks`, each check runs
/// to its end and the limit is weighed between them, so at least one check completes: for waits whose limit means
/// "how long to wait for something to appear", where one read may take longer than that, as the first accessibility
/// read after a boot does. A zero limit then means one check.
@MainActor
func poll<Value>(every interval: Duration, within limit: Duration, finishingChecks: Bool = false,
                 until check: @escaping @MainActor () async throws -> Value?) async throws -> Value? {
    guard !finishingChecks else {
        let deadline = ContinuousClock.now + limit
        while true {
            if let value = try await check() { return value }
            guard ContinuousClock.now < deadline else { return nil }
            try await Task.sleep(for: interval)
        }
    }
    let found = try await withDeadline(limit) { () async throws -> Value in
        while true {
            if let value = try await check() { return value }
            try await Task.sleep(for: interval)
        }
    }
    return found
}

/// The two contenders of `withDeadline`, and the continuation the first to finish resumes. Main-actor only.
@MainActor
private final class DeadlineRace<Value> {
    enum Outcome {
        case finished(Result<Value, any Error>)
        case timedOut
        case cancelled
    }

    private var continuation: CheckedContinuation<MainActorBox<Outcome>, Never>?
    private var isDone = false
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func start(_ continuation: CheckedContinuation<MainActorBox<Outcome>, Never>, limit: Duration,
               operation: @escaping @MainActor () async throws -> Value) {
        guard !isDone else {
            // Cancelled before it started.
            continuation.resume(returning: MainActorBox(.cancelled))
            return
        }
        self.continuation = continuation
        work = Task { @MainActor in
            let result: Result<Value, any Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            self.finish(.finished(result))
        }
        timer = Task { @MainActor in
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            self.finish(.timedOut)
        }
    }

    func finish(_ outcome: Outcome) {
        guard !isDone else { return }
        isDone = true
        timer?.cancel()
        if case .finished = outcome {} else { work?.cancel() }
        continuation?.resume(returning: MainActorBox(outcome))
        continuation = nil
    }
}

/// Carries a value through a continuation that is resumed and awaited on the main actor alone.
private struct MainActorBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}
