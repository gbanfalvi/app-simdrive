import Foundation
import SimDriveNative
import Testing
@testable import SimDriveCore

struct DeveloperToolsTests {
    @Test func aToolPastItsLimitIsStoppedAndTimesOut() async throws {
        let started = ContinuousClock.now
        let error = await #expect(throws: SimDriveError.self) {
            try await DeveloperTools.run(["/bin/sleep", "30"], environment: [:], limit: .milliseconds(200), name: "sleep")
        }
        #expect(error?.code == .toolTimeout)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    /// A tool must be seen to exit however its exit races the wait, as when the settings read several domains at once.
    /// Each running tool blocks two dispatch threads, so the batches stay well below the pool's size.
    @Test func toolsRunTogetherAllFinish() async throws {
        for _ in 0..<10 {
            try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        try await DeveloperTools.run(["/usr/bin/true"], environment: [:], limit: .seconds(5), name: "true").succeeded
                    }
                }
                for try await succeeded in group { #expect(succeeded) }
            }
        }
    }

    @Test func aToolWithinItsLimitReturnsItsOutput() async throws {
        let result = try await DeveloperTools.run(["/bin/echo", "done"], environment: [:], limit: .seconds(10), name: "echo")
        #expect(result.succeeded)
        #expect(result.standardOutput == "done\n")
    }
}
