import Foundation
import SimDriveNative
import Testing
@testable import SimDriveCore

struct CommandResponseTests {
    private static func line(_ response: CommandResponse) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder.line.encode(response)) as? [String: Any])
    }

    @Test func aFailureSaysWhetherARetryMayHelp() throws {
        #expect(try Self.line(.failure(SimDriveError(.toolTimeout, "slow")))["retry"] as? Bool == true)
        #expect(try Self.line(.failure(SimDriveError(.noElement, "missing")))["retry"] as? Bool == false)
    }

    @Test func aStepFailureTakesItsStepsAnswer() throws {
        let retryable = SimDriveError(.stepFailed(retryable: true), "step 2 failed")
        #expect(try Self.line(.failure(retryable))["retry"] as? Bool == true)
        #expect(try Self.line(.failure(retryable))["code"] as? String == "step-failed")
        #expect(retryable.code == .stepFailed)
    }

    @Test func successAndUncodedFailuresHaveNoRetry() throws {
        struct Unexpected: Error {}
        #expect(try Self.line(.success(["stopped": true]))["retry"] == nil)
        #expect(try Self.line(.failure(Unexpected()))["retry"] == nil)
    }
}
