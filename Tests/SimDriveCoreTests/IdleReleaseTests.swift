import Testing
@testable import SimDriveCore

@MainActor
struct IdleReleaseTests {
    private static let delay: Duration = .milliseconds(50)

    @Test func aHoldThatOutlastsTheIdlePeriodKeepsTheReleaseWaiting() async throws {
        var releases = 0
        let idle = IdleRelease(after: Self.delay) { releases += 1 }
        await idle.hold {}
        try await Task.sleep(for: Self.delay / 2)
        await idle.hold { try? await Task.sleep(for: Self.delay * 3) }
        #expect(releases == 0)
    }

    /// Waits for the release rather than a fixed time, since the whole suite, which starts 80 tools at once, can delay
    /// the main actor past a few idle periods.
    @Test func theReleaseRunsOnceTheLastHoldHasBeenIdle() async throws {
        var releases = 0
        let idle = IdleRelease(after: Self.delay) { releases += 1 }
        await idle.hold {}
        let deadline = ContinuousClock.now + .seconds(2)
        while releases == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: Self.delay * 2)
        #expect(releases == 1)
    }

    @Test func cancellingStopsThePendingRelease() async throws {
        var releases = 0
        let idle = IdleRelease(after: Self.delay) { releases += 1 }
        await idle.hold {}
        idle.cancel()
        try await Task.sleep(for: Self.delay * 4)
        #expect(releases == 0)
    }
}
