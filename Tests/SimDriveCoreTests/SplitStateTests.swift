import Testing
@testable import SimDriveCore

@MainActor
struct SplitStateTests {
    @Test func theSideBelongsToTheAppItWasSetFor() {
        let state = SplitState()
        state.remember(.right, forApp: 100)
        #expect(state.layout(forApp: 100) == .right)
        #expect(state.layout(forApp: 200) == nil)
        #expect(state.layout(forApp: nil) == nil)
    }

    @Test func forgettingClearsTheSide() {
        let state = SplitState()
        state.remember(.left, forApp: 100)
        state.forget()
        #expect(state.layout(forApp: 100) == nil)
    }

    @Test func aSideSetWithoutAKnownAppIsNotKept() {
        let state = SplitState()
        state.remember(.left, forApp: nil)
        #expect(state.layout(forApp: nil) == nil)
    }
}
