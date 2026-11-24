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

    @Test func theReleaseRunsOnceTheLastHoldHasBeenIdle() async throws {
        var releases = 0
        let idle = IdleRelease(after: Self.delay) { releases += 1 }
        await idle.hold {}
        try await Task.sleep(for: Self.delay * 4)
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
