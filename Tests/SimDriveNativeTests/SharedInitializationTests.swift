import Testing
@testable import SimDriveNative

@MainActor
struct SharedInitializationTests {
    private static let timeout = SimDriveError(ErrorCode(rawValue: "test-timeout"), "timed out")
    private static let failure = SimDriveError(ErrorCode(rawValue: "test-failure"), "failed")

    @Test func concurrentCallersShareOneRun() async throws {
        var runs = 0
        let shared = SharedInitialization(within: .seconds(5), timeout: Self.timeout) { () async throws -> Int in
            runs += 1
            try await Task.sleep(for: .milliseconds(50))
            return runs
        }
        async let first = shared.value()
        async let second = shared.value()
        #expect(try await [first, second] == [1, 1])
        #expect(try await shared.value() == 1)
        #expect(runs == 1)
    }

    @Test func aTimedOutRunIsForgotten() async throws {
        var runs = 0
        let shared = SharedInitialization(within: .milliseconds(50), timeout: Self.timeout) { () async throws -> Int in
            runs += 1
            if runs == 1 {
                try await Task.sleep(for: .seconds(5))
            }
            return runs
        }
        await #expect(throws: Self.timeout) { try await shared.value() }
        #expect(try await shared.value() == 2)
    }

    @Test func aFailedRunIsForgotten() async throws {
        var runs = 0
        let shared = SharedInitialization(within: .seconds(5), timeout: Self.timeout) { () async throws -> Int in
            runs += 1
            if runs == 1 {
                throw Self.failure
            }
            return runs
        }
        await #expect(throws: Self.failure) { try await shared.value() }
        #expect(try await shared.value() == 2)
    }
}
