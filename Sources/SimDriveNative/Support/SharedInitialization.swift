/// Runs one initialization for every caller, each waiting at most `limit`. A failed or timed-out run is forgotten.
@MainActor
final class SharedInitialization<Value> {
    // A Task's result must be Sendable; the value never leaves the main actor.
    private struct MainActorValue: @unchecked Sendable {
        let value: Value
    }

    private let limit: Duration
    private let timeout: SimDriveError
    private let initialize: @MainActor () async throws -> Value
    private var value: Value?
    private var run: Task<MainActorValue, any Error>?

    init(within limit: Duration, timeout: SimDriveError, _ initialize: @escaping @MainActor () async throws -> Value) {
        self.limit = limit
        self.timeout = timeout
        self.initialize = initialize
    }

    func value() async throws -> Value {
        if let value {
            return value
        }
        let run = self.run ?? Task { [initialize] in MainActorValue(value: try await initialize()) }
        self.run = run
        do {
            let result = try await waitForCompletion(within: limit, timeout: timeout) { done in
                Task { done(await run.result) }
            }.get()
            value = result.value
            return result.value
        } catch {
            if self.run == run {
                self.run = nil
            }
            throw error
        }
    }
}
