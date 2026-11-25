import Foundation
import Testing
@testable import SimDriveCore

/// Real but short durations, with wide margins, so a loaded machine does not fail them.
@MainActor
struct DeadlineTests {
    private static let limit: Duration = .milliseconds(200)
    /// Far past the limit: a wait that took this long did not return at its deadline.
    private static let late: Duration = .seconds(2)

    @Test func pollReturnsTheFirstValue() async throws {
        var checks = 0
        let value = try await poll(every: .milliseconds(10), within: .seconds(5)) { () -> Int? in
            checks += 1
            return checks == 3 ? 42 : nil
        }
        #expect(value == 42)
        #expect(checks == 3)
    }

    @Test func pollGivesUpAtItsLimit() async throws {
        let start = ContinuousClock.now
        let value = try await poll(every: .milliseconds(10), within: Self.limit) { () -> Int? in nil }
        #expect(value == nil)
        #expect(ContinuousClock.now - start < Self.late)
    }

    /// The limit bounds a check that runs long itself, as an accessibility read retrying for 20 s did (I18).
    @Test func theLimitCancelsACheckInProgress() async throws {
        var wasCancelled = false
        let start = ContinuousClock.now
        let value = try await poll(every: .milliseconds(10), within: Self.limit) { () -> Int? in
            do { try await Task.sleep(for: .seconds(30)) } catch { wasCancelled = true }
            return nil
        }
        #expect(value == nil)
        #expect(ContinuousClock.now - start < Self.late)
        try await Task.sleep(for: .milliseconds(50))
        #expect(wasCancelled)
    }

    /// A guest call cannot be cancelled; the deadline must still return on time.
    @Test func aDeadlineReturnsThoughTheOperationIgnoresCancellation() async throws {
        let start = ContinuousClock.now
        let value = try await withDeadline(Self.limit) { () -> Int in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { continuation.resume(returning: 1) }
            }
        }
        #expect(value == nil)
        #expect(ContinuousClock.now - start < Self.late)
    }

    @Test func finishingChecksWithAZeroLimitChecksOnce() async throws {
        var checks = 0
        let value = try await poll(every: .milliseconds(10), within: .zero, finishingChecks: true) { () -> Int? in
            checks += 1
            return nil
        }
        #expect(value == nil)
        #expect(checks == 1)
    }

    /// `tap --label --timeout 2000` must still find an element whose first read takes longer than that.
    @Test func finishingChecksLetsASlowCheckComplete() async throws {
        let value = try await poll(every: .milliseconds(10), within: .milliseconds(50), finishingChecks: true) { () -> Int? in
            try await Task.sleep(for: .milliseconds(300))
            return 7
        }
        #expect(value == 7)
    }

    @Test func errorsFromTheOperationPassThrough() async {
        await #expect(throws: CancellationError.self) {
            _ = try await withDeadline(.seconds(5)) { () -> Int in throw CancellationError() }
        }
    }

    @Test func cancellingTheCallerCancelsTheOperation() async throws {
        var wasCancelled = false
        let caller = Task { @MainActor in
            try await withDeadline(.seconds(30)) { () -> Int in
                do { try await Task.sleep(for: .seconds(30)) } catch { wasCancelled = true; throw error }
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        caller.cancel()
        await #expect(throws: CancellationError.self) { _ = try await caller.value }
        try await Task.sleep(for: .milliseconds(50))
        #expect(wasCancelled)
    }
}
