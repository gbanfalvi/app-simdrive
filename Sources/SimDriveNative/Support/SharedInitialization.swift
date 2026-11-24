/// Runs one initialization for every caller, each waiting at most `limit`. A failed run is forgotten, so the next caller
/// starts another. A run that outlasts a caller's limit is kept, so later callers wait on it again rather than start runs
/// that pile up behind a stalled service.
@MainActor
final class SharedInitialization<Value> {
    private let limit: Duration
    private let timeout: SimDriveError
    private let initialize: @MainActor () async throws -> Value
    private var value: Value?
    private var run: Task<MainActorValue<Value>, any Error>?

    init(within limit: Duration, timeout: SimDriveError, _ initialize: @escaping @MainActor () async throws -> Value) {
        self.limit = limit
        self.timeout = timeout
        self.initialize = initialize
    }

    func value() async throws -> Value {
        if let value {
            return value
        }
        let run = self.run ?? Task { [initialize] in MainActorValue(try await initialize()) }
        self.run = run
        let result = try await waitForCompletion(within: limit, timeout: timeout) { done in
            Task { done(await run.result) }
        }
        switch result {
        case .success(let finished):
            value = finished.value
            return finished.value
        case .failure(let error):
            if self.run == run {
                self.run = nil
            }
            throw error
        }
    }
}
