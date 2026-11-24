/// Runs a release once nothing has held it for an idle period. Holding it stops the pending release until the hold ends,
/// so the release never runs while an input is still using what it closes.
@MainActor
final class IdleRelease {
    private let delay: Duration
    private let release: @MainActor () async -> Void
    private var holds = 0
    private var pending: Task<Void, Never>?

    init(after delay: Duration, _ release: @escaping @MainActor () async -> Void) {
        self.delay = delay
        self.release = release
    }

    /// Runs `body` with the release held, then starts the idle period again.
    func hold<Value>(_ body: () async throws -> Value) async rethrows -> Value {
        cancel()
        holds += 1
        defer {
            holds -= 1
            if holds == 0 { schedule() }
        }
        return try await body()
    }

    /// Stops the pending release, as when the release runs now for another reason.
    func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func schedule() {
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, holds == 0 else { return }
            pending = nil
            await release()
        }
    }
}
