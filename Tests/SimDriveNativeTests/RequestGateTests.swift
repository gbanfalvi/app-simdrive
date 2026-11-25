import Foundation
import Testing
@testable import SimDriveNative

struct RequestGateTests {
    @Test func aSecondRequestWaitsUntilTheFirstIsAnswered() async {
        let gate = RequestGate()
        #expect(gate.enter(before: .distantFuture))
        let second = Task.detached { gate.enter(before: Date(timeIntervalSinceNow: 5)) }
        try? await Task.sleep(for: .milliseconds(100))
        gate.answered(wasAbandoned: false)
        #expect(await second.value)
    }

    /// The guest still holds an unanswered request, so a new one is not sent behind it (F33).
    @Test func aRequestBehindAnUnansweredOneGivesUpAtItsDeadline() {
        let gate = RequestGate()
        #expect(gate.enter(before: .distantFuture))
        gate.abandon()
        let start = Date()
        #expect(!gate.enter(before: Date(timeIntervalSinceNow: 0.2)))
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(gate.abandoned == 1)
    }

    @Test func aLateAnswerClearsTheAbandonedRequest() {
        let gate = RequestGate()
        #expect(gate.enter(before: .distantFuture))
        gate.abandon()
        gate.answered(wasAbandoned: true)
        #expect(gate.abandoned == 0)
        #expect(gate.enter(before: Date(timeIntervalSinceNow: 0.2)))
    }
}
