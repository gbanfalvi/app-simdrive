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

    /// Tools that outlive the dispatch pool's ~64 threads still finish on time: a running tool blocks no thread (I18).
    /// When each blocked two, about 30 sleeping tools at once stalled every other tool until their limits.
    @Test func manyRunningToolsBlockNoThreads() async throws {
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<80 {
                group.addTask {
                    try await DeveloperTools.run(["/bin/sleep", "1"], environment: [:], limit: .seconds(20), name: "sleep").succeeded
                }
            }
            for try await succeeded in group { #expect(succeeded) }
        }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    /// Output larger than a pipe's buffer must not block the tool before it exits.
    @Test func largeOutputIsCollectedWhole() async throws {
        let result = try await DeveloperTools.run(["/bin/sh", "-c", "head -c 300000 /dev/zero | tr '\\0' x; echo oops >&2"],
                                                  environment: [:], limit: .seconds(10), name: "sh")
        #expect(result.standardOutput.count == 300_000)
        #expect(result.standardError == "oops\n")
    }

    @Test func aToolWithinItsLimitReturnsItsOutput() async throws {
        let result = try await DeveloperTools.run(["/bin/echo", "done"], environment: [:], limit: .seconds(10), name: "echo")
        #expect(result.succeeded)
        #expect(result.standardOutput == "done\n")
    }
}
